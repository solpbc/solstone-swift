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

    private enum AttemptPhase {
        case loading
        case loaded
        case terminalError
    }

    private static let interruptedDomain = "WebKitErrorDomain"
    private static let interruptedCode = 102
    private static let unknownGeneration = -1

    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let load: @MainActor (URLRequest) -> AnyObject?
    private let setState: @MainActor (JournalWebPresentation.LoadState) -> Void

    private var boundTask: Task<Void, Never>?
    private var generation = 0
    private var currentNavigation: AnyObject?
    private var expectedNavigation: AnyObject?
    // Strong retired references prevent object-identity address reuse while stale
    // callbacks can still arrive. This grows with superseded loads in one sheet
    // lifetime and is released wholesale on teardown.
    private var retiredNavigations: [ObjectIdentifier: AnyObject] = [:]
    private var unkeyedCallbacksSealed = false
    private var attemptPhase: AttemptPhase = .loading
    private var liveAuthority: JournalWebNavigationPolicy.Authority?
    private var lastRequest: LastRequest?
    private var isTornDown = false

    init(
        timeout: Duration = .seconds(20),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        load: @escaping @MainActor (URLRequest) -> AnyObject?,
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

        self.retire(self.currentNavigation)
        self.retire(self.expectedNavigation)
        let previousRequest = self.lastRequest
        self.lastRequest = request
        self.liveAuthority = JournalWebNavigationPolicy.authority(for: url)

        if let previousRequest, previousRequest.url != url {
            journalWebLog.info("event=reload_rotation generation=\(self.generation, privacy: .public)")
        } else if let previousRequest, previousRequest.reloadToken != reloadToken {
            journalWebLog.info("event=retry generation=\(self.generation, privacy: .public)")
        }

        self.issueProgrammaticLoad(URLRequest(url: url))
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
            if self.attemptPhase == .terminalError {
                journalWebLog.info("event=policy_rewrite_suppressed_terminal_error schemeClass=\(schemeClass, privacy: .public) hostPortMatch=\(hostPortMatch, privacy: .public) generation=\(self.generation, privacy: .public)")
                return decision
            }
            journalWebLog.info("event=policy_rewrite schemeClass=\(schemeClass, privacy: .public) hostPortMatch=\(hostPortMatch, privacy: .public) generation=\(self.generation, privacy: .public)")
            self.retire(self.currentNavigation)
            self.retire(self.expectedNavigation)
            self.issueProgrammaticLoad(JournalWebNavigationPolicy.replacementRequest(from: request, rewrittenURL: rewrittenURL))
        }

        return decision
    }

    func didStart(navigation: AnyObject?) {
        guard !self.isTornDown else { return }
        if self.attemptPhase == .terminalError {
            journalWebLog.info("event=start_ignored_terminal_error generation=\(self.generation, privacy: .public)")
            return
        }
        if let navigation, self.isRetired(navigation) {
            journalWebLog.info("event=start_ignored_retired_navigation generation=\(self.generation, privacy: .public)")
            return
        }
        // WKWebView.load can return nil; without a token, the first start remains
        // accepted and the requestLoad-bound timeout stays the backstop.
        if let expectedNavigation = self.expectedNavigation {
            guard let navigation, navigation === expectedNavigation else {
                journalWebLog.info("event=start_ignored_unexpected_navigation generation=\(self.generation, privacy: .public)")
                return
            }
            self.expectedNavigation = nil
        }
        let previousGeneration = self.generation
        self.generation += 1
        self.currentNavigation = navigation
        self.unkeyedCallbacksSealed = false
        journalWebLog.info("event=start generation=\(self.generation, privacy: .public) previousGeneration=\(previousGeneration, privacy: .public)")
        self.attemptPhase = .loading
        self.setState(JournalWebPresentation.loadState(for: .started))
        self.armBound(generation: self.generation)
    }

    func didCommit(navigation: AnyObject?) {
        guard !self.isTornDown else { return }
        let navigationGeneration = self.generation(for: navigation)
        journalWebLog.info("event=commit navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
        guard self.acceptsTerminalSuccess(navigation: navigation) else { return }
        self.cancelBound()
        self.attemptPhase = .loaded
        self.setState(JournalWebPresentation.loadState(for: .committed))
    }

    func didFinish(navigation: AnyObject?) {
        guard !self.isTornDown else { return }
        let navigationGeneration = self.generation(for: navigation)
        journalWebLog.info("event=finish navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
        guard self.acceptsTerminalSuccess(navigation: navigation) else { return }
        self.cancelBound()
        self.attemptPhase = .loaded
        self.setState(JournalWebPresentation.loadState(for: .finished))
    }

    func didFail(navigation: AnyObject?, error: any Error) {
        guard !self.isTornDown else { return }
        let nsError = error as NSError
        let navigationGeneration = self.generation(for: navigation)

        if Self.isCancellationShaped(nsError) {
            journalWebLog.info("event=superseded domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
            return
        }

        journalWebLog.error("event=failure domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) navigationGeneration=\(navigationGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)")
        guard self.acceptsExplicitFailure(navigation: navigation) else { return }
        self.cancelBound()
        if let navigation {
            self.retire(navigation)
        } else {
            self.unkeyedCallbacksSealed = true
        }
        self.attemptPhase = .terminalError
        self.setState(JournalWebPresentation.loadState(for: .failed(urlErrorCode: nsError.code)))
    }

    func teardown() {
        self.isTornDown = true
        self.cancelBound()
        self.currentNavigation = nil
        self.expectedNavigation = nil
        self.retiredNavigations.removeAll()
        self.unkeyedCallbacksSealed = true
        self.attemptPhase = .loading
        self.liveAuthority = nil
        self.lastRequest = nil
    }

    private func armBound(generation: Int) {
        self.cancelBound()
        self.boundTask = Task { @MainActor in
            await self.sleep(self.timeout)
            guard !Task.isCancelled else { return }
            guard self.generation == generation else { return }
            self.attemptPhase = .terminalError
            self.retire(self.expectedNavigation)
            self.expectedNavigation = nil
            self.unkeyedCallbacksSealed = true
            if let currentNavigation = self.currentNavigation {
                self.retire(currentNavigation)
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

    private func issueProgrammaticLoad(_ request: URLRequest) {
        self.attemptPhase = .loading
        self.unkeyedCallbacksSealed = true
        self.setState(JournalWebPresentation.loadState(for: .started))
        self.armBound(generation: self.generation)
        self.expectedNavigation = self.load(request)
    }

    private func acceptsTerminalSuccess(navigation: AnyObject?) -> Bool {
        guard let navigation else {
            return self.currentNavigation == nil && self.acceptsUnkeyedCallback()
        }
        if self.isRetired(navigation) {
            return false
        }
        guard let currentNavigation = self.currentNavigation else { return false }
        return currentNavigation === navigation
    }

    private func acceptsExplicitFailure(navigation: AnyObject?) -> Bool {
        guard let navigation else {
            return self.currentNavigation == nil && self.acceptsUnkeyedCallback()
        }
        if self.isRetired(navigation) {
            return false
        }
        guard let currentNavigation = self.currentNavigation else { return false }
        return currentNavigation === navigation
    }

    private func acceptsUnkeyedCallback() -> Bool {
        // Unknown-key callbacks fail closed while a programmatic load is pending
        // and after terminal errors. The bound remains the backstop, so the veil
        // cannot stick forever.
        !self.unkeyedCallbacksSealed
    }

    private func generation(for navigation: AnyObject?) -> Int {
        if let navigation, self.isRetired(navigation) {
            return Self.unknownGeneration
        }
        guard let navigation,
              let currentNavigation = self.currentNavigation,
              navigation === currentNavigation
        else {
            return Self.unknownGeneration
        }
        return self.generation
    }

    private func retire(_ navigation: AnyObject?) {
        guard let navigation else { return }
        self.retiredNavigations[ObjectIdentifier(navigation)] = navigation
    }

    private func isRetired(_ navigation: AnyObject) -> Bool {
        self.retiredNavigations.values.contains { retiredNavigation in
            retiredNavigation === navigation
        }
    }

    private static func isCancellationShaped(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return true
        }
        return error.domain == Self.interruptedDomain && error.code == Self.interruptedCode
    }
}
