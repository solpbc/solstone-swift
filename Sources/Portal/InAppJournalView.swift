// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WebKit

struct JournalWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    @Binding var loadState: JournalWebPresentation.LoadState

    func makeCoordinator() -> Coordinator {
        Coordinator { state in
            self.loadState = state
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.requestLoad(url: self.url, reloadToken: self.reloadToken, webView: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.requestLoad(url: self.url, reloadToken: self.reloadToken, webView: uiView)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    nonisolated final class Coordinator: NSObject, WKNavigationDelegate, @unchecked Sendable {
        private let setState: @MainActor (JournalWebPresentation.LoadState) -> Void
        @MainActor private var session: JournalWebNavigationSession?

        init(setState: @escaping @MainActor (JournalWebPresentation.LoadState) -> Void) {
            self.setState = setState
        }

        @MainActor
        func requestLoad(url: URL, reloadToken: Int, webView: WKWebView) {
            self.session(for: webView).requestLoad(url: url, reloadToken: reloadToken)
        }

        @MainActor
        func teardown() {
            self.session?.teardown()
            self.session = nil
        }

        @MainActor
        private func session(for webView: WKWebView) -> JournalWebNavigationSession {
            if let session = self.session {
                return session
            }
            let session = JournalWebNavigationSession(
                load: { [weak webView] request in
                    webView?.load(request)
                },
                setState: self.setState
            )
            self.session = session
            return session
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let request = navigationAction.request
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            Task { @MainActor in
                let decision = self.session(for: webView).decidePolicy(for: request, isMainFrame: isMainFrame)
                switch decision {
                case .allow:
                    decisionHandler(.allow)
                case .rewrite:
                    decisionHandler(.cancel)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let navigationKey = Self.navigationKey(for: navigation)
            Task { @MainActor in
                self.session(for: webView).didStart(navigationKey: navigationKey)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            let navigationKey = Self.navigationKey(for: navigation)
            Task { @MainActor in
                self.session(for: webView).didCommit(navigationKey: navigationKey)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let navigationKey = Self.navigationKey(for: navigation)
            Task { @MainActor in
                self.session(for: webView).didFinish(navigationKey: navigationKey)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            let navigationKey = Self.navigationKey(for: navigation)
            Task { @MainActor in
                self.session(for: webView).didFail(navigationKey: navigationKey, error: error)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            let navigationKey = Self.navigationKey(for: navigation)
            Task { @MainActor in
                self.session(for: webView).didFail(navigationKey: navigationKey, error: error)
            }
        }

        private nonisolated static func navigationKey(for navigation: WKNavigation?) -> ObjectIdentifier? {
            navigation.map { ObjectIdentifier($0) }
        }
    }
}

struct InAppJournalView: View {
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(\.dismiss) private var dismiss
    @State private var loadState: JournalWebPresentation.LoadState = .loading
    @State private var reloadToken = 0

    private var resolvedURL: URL? {
        JournalWebPresentation.resolvedURL(activeLocalPort: self.observerRegistration.activeLocalPort)
    }

    var body: some View {
        NavigationStack {
            self.content
                .navigationTitle("journal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            self.dismiss()
                        }
                    }
                }
        }
        .onChange(of: self.observerRegistration.activeLocalPort) { _, newPort in
            if newPort == nil {
                self.loadState = JournalWebPresentation.connectionLostState
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = self.resolvedURL {
            ZStack {
                JournalWebView(url: url, reloadToken: self.reloadToken, loadState: self.$loadState)
                self.stateOverlay
            }
        } else {
            self.errorView(message: JournalWebPresentation.connectionLostMessage)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch self.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground).opacity(0.75))
        case .loaded:
            EmptyView()
        case .error(let message):
            self.errorView(message: message)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("try again", action: self.retry)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("attempts to reconnect to your journal")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func retry() {
        guard self.resolvedURL != nil else {
            self.loadState = JournalWebPresentation.connectionLostState
            return
        }
        self.reloadToken += 1
    }
}
