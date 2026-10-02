// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit
import WebKit

@MainActor
final class JournalWebActivationRouter {
    typealias Opener = @MainActor (URL) async -> Bool

    private let session: JournalWebNavigationSession
    private let opener: Opener
    private var isTornDown = false
    private var isHandlingActivation = false

    init(session: JournalWebNavigationSession, opener: @escaping Opener) {
        self.session = session
        self.opener = opener
    }

    func handleNavigationAction(
        frame: JournalWebNavigationPolicy.Frame,
        request: URLRequest,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) async {
        guard !self.isTornDown else {
            decisionHandler(.cancel)
            return
        }
        if frame == .subframe {
            _ = self.session.decidePolicy(for: request, frame: frame)
            decisionHandler(.allow)
            return
        }
        guard !self.isHandlingActivation else {
            decisionHandler(.cancel)
            return
        }

        self.isHandlingActivation = true
        let decision = self.session.decidePolicy(for: request, frame: frame)
        switch decision {
        case .allow where frame == .noTarget:
            decisionHandler(.cancel)
            self.isHandlingActivation = false
            self.session.loadInCurrentView(request)
        case .allow:
            decisionHandler(.allow)
            self.isHandlingActivation = false
        case .cancel:
            decisionHandler(.cancel)
            self.isHandlingActivation = false
        case .rewrite:
            decisionHandler(.cancel)
            self.isHandlingActivation = false
        case .openExternally(let url):
            decisionHandler(.cancel)
            self.isHandlingActivation = false
            let opened = await self.opener(url)
            guard !self.isTornDown else { return }
            if !opened {
                self.session.noteOpenRejected()
            }
        }
    }

    func handleNewWindow(request: URLRequest) -> WKWebView? {
        guard !self.isTornDown, !self.isHandlingActivation else { return nil }

        self.isHandlingActivation = true
        let decision = self.session.decidePolicy(for: request, frame: .noTarget)
        switch decision {
        case .allow:
            self.isHandlingActivation = false
            self.session.loadInCurrentView(request)
        case .cancel, .rewrite:
            self.isHandlingActivation = false
        case .openExternally(let url):
            self.isHandlingActivation = false
            Task { @MainActor [weak self] in
                guard let self, !self.isTornDown else { return }
                let opened = await self.opener(url)
                guard !self.isTornDown else { return }
                if !opened {
                    self.session.noteOpenRejected()
                }
            }
        }
        return nil
    }

    func teardown() {
        self.isTornDown = true
    }
}

@MainActor
enum JournalSystemOpen {
    static func live(_ url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(
                url,
                options: [:],
                completionHandler: { accepted in
                    continuation.resume(returning: accepted)
                }
            )
        }
    }
}
