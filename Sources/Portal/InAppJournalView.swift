// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel
import SwiftUI
import WebKit

/// The journal deliberately uses `WKWebView`'s delegate surface rather than
/// SwiftUI `WebView`/`WebPage`: each load returns a stable `WKNavigation`
/// identity and WebKit reports provisional failures, post-commit failures, and
/// content-process termination directly. The SwiftUI API's global navigation
/// sequence cannot correlate those events to an individual load.
struct JournalWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    @Binding var loadState: JournalWebPresentation.LoadState
    let diagnosticLog: DiagnosticLog

    func makeCoordinator() -> Coordinator {
        Coordinator(diagnosticLog: self.diagnosticLog) { state in
            self.loadState = state
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.observeForeground(of: webView)
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
        private let diagnosticLog: DiagnosticLog
        @MainActor private var session: JournalWebNavigationSession?
        @MainActor private var latestLoad: (url: URL, reloadToken: Int)?
        @MainActor private var isTornDown = false
        @MainActor private var foregroundObserver: (any NSObjectProtocol)?

        init(
            diagnosticLog: DiagnosticLog,
            setState: @escaping @MainActor (JournalWebPresentation.LoadState) -> Void
        ) {
            self.diagnosticLog = diagnosticLog
            self.setState = setState
        }

        /// Every programmatic load first sets the loopback capability cookie in
        /// this web view's store and waits for it, so the load and every request
        /// its page makes carry it. Re-setting per load, not once, recovers a
        /// cookie lost with the WebKit network process on the next reload.
        @MainActor
        func requestLoad(url: URL, reloadToken: Int, webView: WKWebView) {
            guard !self.isTornDown,
                  self.latestLoad?.url != url || self.latestLoad?.reloadToken != reloadToken
            else { return }
            self.latestLoad = (url, reloadToken)
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor [weak self, weak webView] in
                if url.host == "127.0.0.1", let cookie = LoopbackCapability.process.httpCookie() {
                    await cookieStore.setCookie(cookie)
                }
                // A newer load or a teardown may have arrived while the cookie
                // was being set; only the latest request proceeds.
                guard let self, let webView, !self.isTornDown,
                      self.latestLoad?.url == url, self.latestLoad?.reloadToken == reloadToken
                else { return }
                self.creatingSession(for: webView).requestLoad(url: url, reloadToken: reloadToken)
            }
        }

        /// Re-sets the capability cookie when the app returns to the foreground.
        /// iOS may reclaim the WebKit network process while the app is
        /// suspended, taking the session cookie with it; the page on screen
        /// would then be refused on its next fetch or live-update reconnect.
        @MainActor
        func observeForeground(of webView: WKWebView) {
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            self.foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    if let cookie = LoopbackCapability.process.httpCookie() {
                        await cookieStore.setCookie(cookie)
                    }
                }
            }
        }

        @MainActor
        func teardown() {
            if let foregroundObserver = self.foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
                self.foregroundObserver = nil
            }
            self.isTornDown = true
            self.session?.teardown()
            self.session = nil
        }

        @MainActor
        private func creatingSession(for webView: WKWebView) -> JournalWebNavigationSession {
            if let session = self.session {
                return session
            }
            let session = JournalWebNavigationSession(
                load: { [weak webView] request in
                    webView?.load(request)
                },
                setState: self.setState,
                diagnosticLog: self.diagnosticLog
            )
            self.session = session
            return session
        }

        @MainActor
        private var existingSession: JournalWebNavigationSession? {
            self.session
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let request = navigationAction.request
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            Task { @MainActor in
                guard let session = self.existingSession else {
                    decisionHandler(.allow)
                    return
                }
                switch session.decidePolicy(for: request, isMainFrame: isMainFrame) {
                case .allow:
                    decisionHandler(.allow)
                case .rewrite:
                    decisionHandler(.cancel)
                case .openExternally(let url):
                    decisionHandler(.cancel)
                    UIApplication.shared.open(url)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                self.existingSession?.didStart(navigation: navigation)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            Task { @MainActor in
                self.existingSession?.didReceiveServerRedirect(navigation: navigation)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor in
                self.existingSession?.didCommit(navigation: navigation)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.existingSession?.didFinish(navigation: navigation)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            Task { @MainActor in
                self.existingSession?.didFail(navigation: navigation, error: error)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            Task { @MainActor in
                self.existingSession?.didFail(navigation: navigation, error: error)
            }
        }

        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                self.existingSession?.webContentProcessDidTerminate()
            }
        }
    }
}

struct InAppJournalView: View {
    var mark: JournalMark? = nil
    var presentation: ShellPanePresentation = .phoneModal
    var path: String = "/"
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var loadState: JournalWebPresentation.LoadState = .loading
    @State private var reloadToken = 0

    private var resolvedURL: URL? {
        JournalWebPresentation.resolvedURL(
            activeLocalPort: self.tunnelManager.activeConnection?.port,
            path: self.path
        )
    }

    private var headingString: String {
        journalPaneTitle(mark: self.mark)
    }

    @ViewBuilder
    var body: some View {
        if self.presentation.isPhoneModal {
            NavigationStack {
                self.paneContent
            }
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) {
                self.dismiss()
            }
            .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            self.paneContent
        }
    }

    private var paneContent: some View {
        self.content
            // Explicit and independent of `ShellSurface`: the journal is the one native
            // pane that must stay opaque under the shared SunArc background, because the
            // `WKWebView` beneath it has no ground of its own to fall back on.
            .background(Color.deckGround.ignoresSafeArea())
            .navigationTitle(self.headingString)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if self.presentation.isPhoneModal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            self.dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if let mark = self.mark {
                            JournalMarkCompactChips(mark: mark)
                        } else {
                            JournalMarkCompactGenericChips()
                        }
                        Text(self.headingString)
                    }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(self.headingString)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("shell.pane.journal.heading")
                        .accessibilityFocused(self.$headingFocused)
                }
            }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.pane.journal")
        .onAppear { self.headingFocused = true }
        .onChange(of: self.tunnelManager.activeConnection?.port) { _, newPort in
            if newPort == nil {
                self.loadState = JournalWebPresentation.connectionLostState
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = self.resolvedURL {
            ZStack {
                JournalWebView(
                    url: url,
                    reloadToken: self.reloadToken,
                    loadState: self.$loadState,
                    diagnosticLog: self.diagnosticLog
                )
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
                .background(Color.deckGround.opacity(0.75))
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
        .background(Color.deckGround)
    }

    private func retry() {
        guard self.resolvedURL != nil else {
            self.loadState = JournalWebPresentation.connectionLostState
            return
        }
        self.reloadToken += 1
    }

}
