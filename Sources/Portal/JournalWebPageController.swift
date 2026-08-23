// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import WebKit

@MainActor
final class JournalWebSessionBox {
    var session: JournalWebNavigationSession?
}

@MainActor
struct JournalWebNavigationDecider: WebPage.NavigationDeciding {
    let sessionBox: JournalWebSessionBox

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        let isMainFrame = action.target?.isMainFrame == true
        return journalWebActionPolicy(
            session: self.sessionBox.session,
            request: action.request,
            isMainFrame: isMainFrame
        )
    }
}

@MainActor
func journalWebActionPolicy(
    session: JournalWebNavigationSession?,
    request: URLRequest,
    isMainFrame: Bool
) -> WKNavigationActionPolicy {
    guard let session else { return .allow }
    switch session.decidePolicy(for: request, isMainFrame: isMainFrame) {
    case .allow:
        return .allow
    case .rewrite:
        return .cancel
    }
}

/// Bridges `WebPage.navigations` onto `JournalWebNavigationSession`.
///
/// `WebPage.NavigationEvent` has no `WKNavigation` identity. Programmatic
/// `load` still vends a `LoadToken` so the session can match expected
/// navigation; user-initiated starts mint a fresh token when none is pending.
@MainActor
final class JournalWebNavigationBridge {
    var session: JournalWebNavigationSession?
    var pendingToken: JournalWebPageController.LoadToken?
    var currentToken: JournalWebPageController.LoadToken?
    var isTornDown = false
}

@MainActor
@Observable
final class JournalWebPageController {
    final class LoadToken: NSObject {}

    let page: WebPage
    private let session: JournalWebNavigationSession
    private let bridge: JournalWebNavigationBridge
    private var navigationTask: Task<Void, Never>?

    init(setState: @escaping @MainActor (JournalWebPresentation.LoadState) -> Void) {
        let sessionBox = JournalWebSessionBox()
        let bridge = JournalWebNavigationBridge()
        var configuration = WebPage.Configuration()
        configuration.upgradeKnownHostsToHTTPS = false
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested

        let page = WebPage(
            configuration: configuration,
            navigationDecider: JournalWebNavigationDecider(sessionBox: sessionBox)
        )
        self.page = page
        self.bridge = bridge

        let session = JournalWebNavigationSession(
            load: { request in
                let token = LoadToken()
                bridge.pendingToken = token
                Task { @MainActor in
                    guard !bridge.isTornDown else { return }
                    _ = page.load(request)
                }
                return token
            },
            setState: setState
        )
        sessionBox.session = session
        bridge.session = session
        self.session = session
        self.navigationTask = Task { [weak self] in
            await self?.consumeNavigations()
        }
    }

    func requestLoad(url: URL, reloadToken: Int) {
        guard !self.bridge.isTornDown else { return }
        self.session.requestLoad(url: url, reloadToken: reloadToken)
    }

    func teardown() {
        self.bridge.isTornDown = true
        self.navigationTask?.cancel()
        self.navigationTask = nil
        self.session.teardown()
        self.page.stopLoading()
    }

    private func consumeNavigations() async {
        while !Task.isCancelled && !self.bridge.isTornDown {
            do {
                for try await event in self.page.navigations {
                    if Task.isCancelled || self.bridge.isTornDown { return }
                    self.apply(event)
                }
            } catch {
                if Task.isCancelled || self.bridge.isTornDown { return }
                self.applyError(error)
                if Self.isTerminalPageError(error) {
                    return
                }
            }
        }
    }

    private func apply(_ event: WebPage.NavigationEvent) {
        guard let session = self.bridge.session else { return }
        switch event {
        case .startedProvisionalNavigation:
            let token: LoadToken
            if let pending = self.bridge.pendingToken {
                self.bridge.pendingToken = nil
                token = pending
            } else {
                token = LoadToken()
            }
            self.bridge.currentToken = token
            session.didStart(navigation: token)
        case .receivedServerRedirect:
            break
        case .committed:
            session.didCommit(navigation: self.bridge.currentToken)
        case .finished:
            session.didFinish(navigation: self.bridge.currentToken)
        @unknown default:
            break
        }
    }

    private func applyError(_ error: any Error) {
        self.bridge.session?.didFail(
            navigation: self.bridge.currentToken ?? self.bridge.pendingToken,
            error: Self.unpack(error)
        )
    }

    private static func unpack(_ error: any Error) -> any Error {
        guard let navigationError = error as? WebPage.NavigationError else {
            return error
        }
        switch navigationError {
        case .failedProvisionalNavigation(let inner):
            return inner
        case .pageClosed, .webContentProcessTerminated, .invalidURL:
            return navigationError
        @unknown default:
            return navigationError
        }
    }

    private static func isTerminalPageError(_ error: any Error) -> Bool {
        guard let navigationError = error as? WebPage.NavigationError else {
            return false
        }
        switch navigationError {
        case .pageClosed:
            return true
        case .failedProvisionalNavigation, .webContentProcessTerminated, .invalidURL:
            return false
        @unknown default:
            return false
        }
    }
}
