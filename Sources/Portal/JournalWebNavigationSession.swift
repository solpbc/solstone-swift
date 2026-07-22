// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let journalWebLog = Logger(subsystem: "app.solstone.swift", category: "journalweb")

@MainActor
final class JournalWebNavigationSession {
    private struct LastRequest: Equatable {
        let url: URL
        let reloadToken: Int
    }

    private static let interruptedDomain = "WebKitErrorDomain"
    private static let interruptedCode = 102
    private static let unknownGeneration = -1

    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let load: @MainActor (URLRequest) -> Void
    private let setState: @MainActor (JournalWebPresentation.LoadState) -> Void

    private var boundTask: Task<Void, Never>?
    private var generation = 0
    private var currentNavigationKey: ObjectIdentifier?
    private var retiredNavigationKeys: Set<ObjectIdentifier> = []
    private var unkeyedCallbacksSealed = false
    private var liveAuthority: JournalWebNavigationPolicy.Authority?
    private var lastRequest: LastRequest?
    private var isTornDown = false

    init(
        timeout: Duration = .seconds(20),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        load: @escaping @MainActor (URLRequest) -> Void,
        setState: @escaping @MainActor (JournalWebPresentation.LoadState) -> Void
    ) {
        self.timeout = timeout
        self.sleep = sleep
        self.load = load
        self.setState = setState
    }

    func requestLoad(url: URL, reloadToken: Int) {
        guard !self.isTornDown else { return }
        let request = LastRequest(url: url, reloadToken: reloadToken)
        guard self.lastRequest != request else { return }

        self.unkeyedCallbacksSealed = true
        if let currentNavigationKey = self.currentNavigationKey {
            self.retiredNavigationKeys.insert(currentNavigationKey)
        }
        let previousRequest = self.lastRequest
        self.lastRequest = request
        self.liveAuthority = JournalWebNavigationPolicy.authority(for: url)
        self.setState(JournalWebPresentation.loadState(for: .started))
        self.armBound(generation: self.generation)

        if let previousRequest, previousRequest.url != url {
            journalWebLog.info("event=reload_rotation generation=\(self.generation, privacy: .public)")
        } else if let previousRequest, previousRequest.reloadToken != reloadToken {
            journalWebLog.info("event=retry generation=\(self.generation, privacy: .public)")
        }

        self.load(URLRequest(url: url))
    }

    @discardableResult
    func decidePolicy(for request: URLRequest, isMainFrame: Bool) -> JournalWebNavigationPolicy.Decision {
        guard !self.isTornDown else { return .allow }
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: request.url,
            httpMethod: request.httpMethod,
            isMainFrame: isMainFrame,
            liveAuthority: self.liveAuthority
        )
        let schemeClass = JournalWebNavigationPolicy.schemeClass(for: request.url).rawValue
        let hostPortMatch = JournalWebNavigationPolicy.hostPortMatches(
            requestURL: request.url,
            liveAuthority: self.liveAuthority
        )

        switch decision {
        case .allow:
            journalWebLog.info("event=policy_allow schemeClass=\(schemeClass, privacy: .public) hostPortMatch=\(hostPortMatch, privacy: .public) generation=\(self.generation, privacy: .public)")
        case .rewrite(let rewrittenURL):
            journalWebLog.info("event=policy_rewrite schemeClass=\(schemeClass, privacy: .public) hostPortMatch=\(hostPortMatch, privacy: .public) generation=\(self.generation, privacy: .public)")
            self.load(JournalWebNavigationPolicy.replacementRequest(from: request, rewrittenURL: rewrittenURL))
        }

        return decision
    }

    func didStart(navigationKey: ObjectIdentifier?) {
        guard !self.isTornDown else { return }
        let previousGeneration = self.generation
        self.generation += 1
        self.currentNavigationKey = navigationKey
        self.retiredNavigationKeys.removeAll()
        self.unkeyedCallbacksSealed = false
        journalWebLog.info("event=start generation=\(self.generation, privacy: .public) previousGeneration=\(previousGeneration, privacy: .public)")
        self.setState(JournalWebPresentation.loadState(for: .started))
        self.armBound(generation: self.generation)
    }

    func didCommit(navigationKey: ObjectIdentifier?) {
        guard !self.isTornDown else { return }
        let navigationGeneration = self.generation(for: navigationKey)
        journalWebLog.info("event=commit navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
        guard self.acceptsTerminalSuccess(navigationKey: navigationKey) else { return }
        self.cancelBound()
        self.setState(JournalWebPresentation.loadState(for: .committed))
    }

    func didFinish(navigationKey: ObjectIdentifier?) {
        guard !self.isTornDown else { return }
        let navigationGeneration = self.generation(for: navigationKey)
        journalWebLog.info("event=finish navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
        guard self.acceptsTerminalSuccess(navigationKey: navigationKey) else { return }
        self.cancelBound()
        self.setState(JournalWebPresentation.loadState(for: .finished))
    }

    func didFail(navigationKey: ObjectIdentifier?, error: any Error) {
        guard !self.isTornDown else { return }
        let nsError = error as NSError
        let navigationGeneration = self.generation(for: navigationKey)

        if Self.isCancellationShaped(nsError) {
            journalWebLog.info("event=superseded domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
            return
        }

        journalWebLog.error("event=failure domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
        guard self.acceptsExplicitFailure(navigationKey: navigationKey) else { return }
        self.cancelBound()
        self.setState(JournalWebPresentation.loadState(for: .failed(urlErrorCode: nsError.code)))
    }

    func teardown() {
        self.isTornDown = true
        self.cancelBound()
        self.currentNavigationKey = nil
        self.retiredNavigationKeys.removeAll()
        self.unkeyedCallbacksSealed = true
        self.liveAuthority = nil
        self.lastRequest = nil
    }

    private func armBound(generation: Int) {
        self.cancelBound()
        self.boundTask = Task { @MainActor in
            await self.sleep(self.timeout)
            guard !Task.isCancelled else { return }
            guard self.generation == generation else { return }
            self.unkeyedCallbacksSealed = true
            if let currentNavigationKey = self.currentNavigationKey {
                self.retiredNavigationKeys.insert(currentNavigationKey)
            }
            journalWebLog.error("event=timeout generation=\(generation, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
            self.boundTask = nil
            self.setState(JournalWebPresentation.loadState(for: .failed(urlErrorCode: NSURLErrorTimedOut)))
        }
    }

    private func cancelBound() {
        self.boundTask?.cancel()
        self.boundTask = nil
    }

    private func acceptsTerminalSuccess(navigationKey: ObjectIdentifier?) -> Bool {
        guard let navigationKey else {
            return self.currentNavigationKey == nil && self.acceptsUnkeyedCallback()
        }
        if self.retiredNavigationKeys.contains(navigationKey) {
            return false
        }
        guard let currentNavigationKey = self.currentNavigationKey else { return false }
        return currentNavigationKey == navigationKey
    }

    private func acceptsExplicitFailure(navigationKey: ObjectIdentifier?) -> Bool {
        guard let navigationKey else {
            return self.currentNavigationKey == nil && self.acceptsUnkeyedCallback()
        }
        if self.retiredNavigationKeys.contains(navigationKey) {
            return false
        }
        guard let currentNavigationKey = self.currentNavigationKey else { return false }
        return currentNavigationKey == navigationKey
    }

    private func acceptsUnkeyedCallback() -> Bool {
        // Unknown-key callbacks fail closed after requestLoad or timeout. The
        // requestLoad-bound timeout is the backstop, so the veil cannot stick forever.
        !self.unkeyedCallbacksSealed
    }

    private func generation(for navigationKey: ObjectIdentifier?) -> Int {
        if let navigationKey, self.retiredNavigationKeys.contains(navigationKey) {
            return Self.unknownGeneration
        }
        guard let navigationKey,
              let currentNavigationKey = self.currentNavigationKey,
              navigationKey == currentNavigationKey
        else {
            return Self.unknownGeneration
        }
        return self.generation
    }

    private static func isCancellationShaped(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return true
        }
        return error.domain == Self.interruptedDomain && error.code == Self.interruptedCode
    }
}
