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
    var navigationToken: Int = 0
    /// The paired journal; its pages live in that pairing's own data store.
    var journalInstanceID: String? = nil
    let pairingOwnerID: UUID?
    let reconnectLocation: JournalWebReconnectLocation
    @Binding var loadState: JournalWebPresentation.LoadState
    let diagnosticLog: DiagnosticLog
    /// The app's import queue, offered to the journal's own pages; `nil` offers nothing.
    var importIntake: (any JournalImportIntake)? = nil
    var localeLanguage: @Sendable () -> String = { AppStrings.language }

    /// Stable identity keyed on origin + journal instance so navigating between paths on the
    /// same journal (e.g. `/app/import/` -> `/app/import/<id>`) reuses the existing `WKWebView`
    /// in place instead of destroying and recreating it.
    nonisolated static func webViewIdentity(for url: URL, journalInstanceID: String?) -> String {
        let origin = JournalWebNavigationPolicy.authority(for: url)
            .map { "\($0.scheme)://\($0.host):\($0.port)" } ?? url.absoluteString
        let instance = journalInstanceID ?? ""
        return "\(origin)|\(instance)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            diagnosticLog: self.diagnosticLog,
            reconnectLocation: self.reconnectLocation,
            localeLanguage: self.localeLanguage,
            setState: { state in
                self.loadState = state
            }
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = JournalWebHostContractConfiguration.make(diagnosticLog: self.diagnosticLog)
        if let journalInstanceID, !journalInstanceID.isEmpty {
            configuration.websiteDataStore = JournalWebDataStore.store(for: journalInstanceID)
        }
        if let authority = JournalWebNavigationPolicy.authority(for: self.url),
           let localeScript = JournalRequestLocale.fetchLocaleScript(
               origin: "\(authority.scheme)://\(authority.host):\(authority.port)",
               language: self.localeLanguage()
           ) {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: localeScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        let importHost = self.importIntake.flatMap { JournalImportHost(entryURL: self.url, intake: $0) }
        importHost?.install(in: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        importHost?.attach(to: webView)
        context.coordinator.importHost = importHost
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.observeForeground(of: webView)
        let resumeURL = self.reconnectLocation.attach(webView, entryURL: self.url, ownerID: self.pairingOwnerID)
        context.coordinator.requestLoad(
            url: self.url,
            reloadToken: self.reloadToken,
            navigationToken: self.navigationToken,
            webView: webView,
            resumeURL: resumeURL
        )
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.requestLoad(
            url: self.url,
            reloadToken: self.reloadToken,
            navigationToken: self.navigationToken,
            webView: uiView
        )
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.reconnectLocation?.detach(uiView)
        // Items the page queued stay in the app's queue and keep going to the journal.
        coordinator.importHost?.teardown(controller: uiView.configuration.userContentController)
        coordinator.importHost = nil
        coordinator.teardown()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    nonisolated final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, @unchecked Sendable {
        private let setState: @MainActor (JournalWebPresentation.LoadState) -> Void
        private let diagnosticLog: DiagnosticLog
        private let localeLanguage: @Sendable () -> String
        let reconnectLocation: JournalWebReconnectLocation?
        @MainActor private var session: JournalWebNavigationSession?
        @MainActor private var activationRouter: JournalWebActivationRouter?
        @MainActor private var latestLoad: (url: URL, reloadToken: Int, navigationToken: Int)?
        @MainActor private var isTornDown = false
        @MainActor private var foregroundObserver: (any NSObjectProtocol)?
        @MainActor var importHost: JournalImportHost?

        init(
            diagnosticLog: DiagnosticLog,
            reconnectLocation: JournalWebReconnectLocation? = nil,
            localeLanguage: @escaping @Sendable () -> String = { AppStrings.language },
            setState: @escaping @MainActor (JournalWebPresentation.LoadState) -> Void,
            opener: @escaping JournalWebActivationRouter.Opener = JournalSystemOpen.live
        ) {
            self.diagnosticLog = diagnosticLog
            self.reconnectLocation = reconnectLocation
            self.localeLanguage = localeLanguage
            self.setState = setState
            self.opener = opener
        }

        private let opener: JournalWebActivationRouter.Opener
        let panels = JournalWebPanels()

        /// Every programmatic load first sets the loopback capability cookie in
        /// this web view's store and waits for it, so the load and every request
        /// its page makes carry it. Re-setting per load, not once, recovers a
        /// cookie lost with the WebKit network process on the next reload.
        @MainActor
        func requestLoad(
            url: URL,
            reloadToken: Int,
            navigationToken: Int = 0,
            webView: WKWebView,
            resumeURL: URL? = nil
        ) {
            guard !self.isTornDown,
                  self.latestLoad?.url != url
                    || self.latestLoad?.reloadToken != reloadToken
                    || self.latestLoad?.navigationToken != navigationToken
            else { return }
            self.latestLoad = (url, reloadToken, navigationToken)
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor [weak self, weak webView] in
                if url.host == "127.0.0.1", let cookie = LoopbackCapability.process.httpCookie() {
                    await cookieStore.setCookie(cookie)
                }
                // A newer load or a teardown may have arrived while the cookie
                // was being set; only the latest request proceeds.
                guard let self, let webView, !self.isTornDown,
                      self.latestLoad?.url == url,
                      self.latestLoad?.reloadToken == reloadToken,
                      self.latestLoad?.navigationToken == navigationToken
                else { return }
                self.creatingSession(for: webView).requestLoad(
                    url: resumeURL ?? url,
                    reloadToken: reloadToken,
                    navigationToken: navigationToken
                )
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
            self.panels.teardown()
            self.activationRouter?.teardown()
            self.activationRouter = nil
            self.session?.teardown()
            self.session = nil
        }

        @MainActor
        private func creatingSession(for webView: WKWebView) -> JournalWebNavigationSession {
            if let session = self.session {
                return session
            }
            let session = JournalWebNavigationSession(
                restoreLoopbackCookie: { [weak webView] in
                    guard let webView, let cookie = LoopbackCapability.process.httpCookie() else { return }
                    await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                },
                load: { [weak webView] request in
                    webView?.load(request)
                },
                setState: self.setState,
                diagnosticLog: self.diagnosticLog,
                localeLanguage: self.localeLanguage
            )
            self.session = session
            self.activationRouter = JournalWebActivationRouter(session: session, opener: self.opener)
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
            let frame = Self.frame(for: navigationAction.targetFrame)
            Task { @MainActor in
                guard !self.isTornDown else {
                    decisionHandler(.cancel)
                    return
                }
                guard let router = self.activationRouter else {
                    switch frame {
                    case .main, .subframe:
                        decisionHandler(.allow)
                    case .noTarget:
                        decisionHandler(.cancel)
                    }
                    return
                }
                await router.handleNavigationAction(
                    frame: frame,
                    request: request,
                    decisionHandler: decisionHandler
                )
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            let isMainFrame = navigationResponse.isForMainFrame
            let httpResponse = navigationResponse.response as? HTTPURLResponse
            let httpStatus = httpResponse?.statusCode
            let refusalHeader = httpResponse?.value(forHTTPHeaderField: "X-SPL-Loopback-Refused")
            let responseURL = navigationResponse.response.url
            Task { @MainActor [weak self] in
                guard let self, !self.isTornDown else {
                    decisionHandler(.cancel)
                    return
                }
                guard let session = self.session else {
                    decisionHandler(.allow)
                    return
                }
                let snapshot = self.latestLoad
                let decision = session.decideLoopbackResponse(
                    isMainFrame: isMainFrame,
                    httpStatus: httpStatus,
                    refusalHeader: refusalHeader,
                    responseURL: responseURL,
                    stillCurrent: { [weak self] in
                        guard let self, !self.isTornDown else { return false }
                        return (self.latestLoad == nil && snapshot == nil) ||
                            (self.latestLoad?.url == snapshot?.url && self.latestLoad?.reloadToken == snapshot?.reloadToken)
                    }
                )
                decisionHandler(decision == .allow ? .allow : .cancel)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            MainActor.assumeIsolated {
                guard !self.isTornDown, let router = self.activationRouter else { return nil }
                return router.handleNewWindow(request: navigationAction.request)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async {
            _ = await self.panels.present(.alert, message: message, over: webView)
        }

        nonisolated func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async -> Bool {
            await self.panels.present(.confirm, message: message, over: webView) != .cancelled
        }

        nonisolated func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo
        ) async -> String? {
            switch await self.panels.present(.prompt(defaultText: defaultText), message: prompt, over: webView) {
            case .accepted(let text):
                text ?? ""
            case .cancelled:
                nil
            }
        }

        private nonisolated static func frame(for targetFrame: WKFrameInfo?) -> JournalWebNavigationPolicy.Frame {
            guard let targetFrame else { return .noTarget }
            return targetFrame.isMainFrame ? .main : .subframe
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
                self.importHost?.ensureDropInteraction()
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
                self.importHost?.authHost?.tearDown()
                self.existingSession?.webContentProcessDidTerminate()
            }
        }
    }
}

/// The open pane owns this location across web view lifetimes. The attachment is
/// weak so it does not keep an old WebKit view alive after the origin changes.
@MainActor
final class JournalWebReconnectLocation {
    private weak var webView: WKWebView?
    private var entryURL: URL?
    private var ownerID: UUID?
    private var lastAddress: URL?

    func attach(_ webView: WKWebView, entryURL: URL, ownerID: UUID?) -> URL? {
        // SwiftUI can create a replacement before dismantling the old view.
        self.rememberCurrentPage()
        if ownerID == nil || ownerID != self.ownerID || entryURL.path != self.entryURL?.path {
            self.lastAddress = nil
        }
        self.webView = webView
        self.entryURL = entryURL
        self.ownerID = ownerID

        guard let lastAddress = self.lastAddress,
              let previous = URLComponents(url: lastAddress, resolvingAgainstBaseURL: false),
              var target = URLComponents(url: entryURL, resolvingAgainstBaseURL: false)
        else { return nil }
        target.percentEncodedPath = previous.percentEncodedPath
        target.percentEncodedQuery = previous.percentEncodedQuery
        target.percentEncodedFragment = previous.percentEncodedFragment
        return target.url
    }

    func detach(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        self.rememberCurrentPage()
        self.webView = nil
    }

    private func rememberCurrentPage() {
        // The committed history item also tracks history.pushState, replaceState
        // and hash changes, including journal navigation without a document load.
        guard self.ownerID != nil,
              let entryURL = self.entryURL,
              let origin = JournalWebNavigationPolicy.authority(for: entryURL),
              let url = self.webView?.backForwardList.currentItem?.url,
              JournalWebNavigationPolicy.authority(for: url) == origin,
              url.user == nil, url.password == nil
        else { return }
        self.lastAddress = url
    }
}

nonisolated enum InAppJournalPresentation {
    struct WebMount: Equatable, Hashable {
        let url: URL
        let ownerID: UUID?
        let path: String

        func canWaitForReconnect(confirmed: Bool, ownerID: UUID?, path: String) -> Bool {
            confirmed && ownerID != nil && self.ownerID == ownerID && self.path == path
        }
    }

    enum Content: Equatable, Sendable {
        case web
        case awaitingMarkConfirmation
        case connectionLost
    }

    static func shouldLoadWebView(journalSendConfirmed: Bool, resolvedURL: URL?) -> Bool {
        journalSendConfirmed && resolvedURL != nil
    }

    static func content(
        journalSendConfirmed: Bool,
        resolvedURL: URL?,
        awaitingMarkConfirmation: Bool,
        status: ConnectionSyncStatus,
        isStalled: Bool
    ) -> Content {
        if self.shouldLoadWebView(journalSendConfirmed: journalSendConfirmed, resolvedURL: resolvedURL) {
            return .web
        }
        if MarkConfirmationDisplay.showsAwaitingWords(
            awaitingMarkConfirmation: awaitingMarkConfirmation,
            status: status,
            isStalled: isStalled
        ) {
            return .awaitingMarkConfirmation
        }
        return .connectionLost
    }
}

struct InAppJournalView: View {
    var mark: JournalMark? = nil
    var presentation: ShellPanePresentation = .phoneModal
    var path: String = "/"
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(ConnectionStallMonitor.self) private var connectionStallMonitor
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @Environment(PairFlowRouter.self) private var pairFlowRouter
    @Environment(JournalSendRelease.self) private var journalSendRelease: JournalSendRelease?
    @Environment(PendingJournalOpenState.self) private var pendingJournalOpen: PendingJournalOpenState?
    @Environment(ShareTransferHolder.self) private var shareTransferHolder: ShareTransferHolder?
    @Environment(ForegroundDrainGate.self) private var foregroundDrainGate: ForegroundDrainGate?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneBesideDeck) private var paneBesideDeck
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var loadState: JournalWebPresentation.LoadState = .loading
    @State private var reloadToken = 0
    @State private var reconnectLocation = JournalWebReconnectLocation()
    @State private var previousWebMount: InAppJournalPresentation.WebMount?

    private var resolvedURL: URL? {
        JournalWebPresentation.resolvedURL(
            activeLocalPort: self.tunnelManager.activeConnection?.port,
            path: self.path
        )
    }

    private var pairingOwnerID: UUID? { self.appConfig.store.snapshot().deviceOwnerID }

    /// iPad split navigation can recreate the pane independently of the tunnel.
    private var keepsWebViewWhileReconnecting: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var activeWebMount: InAppJournalPresentation.WebMount? {
        guard self.appConfig.isPaired, self.appConfig.journalSendConfirmed, let url = self.resolvedURL else { return nil }
        return .init(url: url, ownerID: self.pairingOwnerID, path: self.path)
    }

    private var webMount: InAppJournalPresentation.WebMount? {
        if let activeWebMount = self.activeWebMount { return activeWebMount }
        guard self.keepsWebViewWhileReconnecting, let previousWebMount = self.previousWebMount,
              previousWebMount.canWaitForReconnect(
                confirmed: self.appConfig.journalSendConfirmed,
                ownerID: self.pairingOwnerID,
                path: self.path
              ) else { return nil }
        return previousWebMount
    }

    private var importIntake: (any JournalImportIntake)? {
        guard let holder = self.shareTransferHolder, let gate = self.foregroundDrainGate else { return nil }
        return JournalImportQueueIntake(holder: holder, drainGate: gate)
    }

    private var journalIdentity: JournalIdentity {
        JournalIdentity.select(
            isPaired: self.appConfig.isPaired,
            sendConfirmed: self.appConfig.journalSendConfirmed,
            mark: self.mark
        )
    }

    private var headingString: String {
        self.journalIdentity.title
    }

    /// Beside the deck the pill already shows the mark, so a bar repeating it above
    /// the journal is only lost height. Without the deck, or above a pushed pane, the
    /// bar stays: it carries the sidebar toggle or the back button.
    private var hidesBar: Bool {
        self.paneBesideDeck && self.appConfig.isPaired
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
            .toolbar(self.hidesBar ? .hidden : .automatic, for: .navigationBar)
            .overlay(alignment: .top) {
                // The pane keeps its standing heading for assistive tech when the bar
                // that draws it is hidden.
                if self.hidesBar {
                    Color.clear
                        .frame(height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(self.journalIdentity.spokenValue)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("shell.pane.journal.heading")
                        .accessibilityFocused(self.$headingFocused)
                }
            }
            .toolbar {
                if self.presentation.isPhoneModal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppStrings.ios_home_done()) {
                            self.dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        JournalMarkCompactChips(identity: self.journalIdentity)
                        JournalMarkInlineWords(words: self.journalIdentity.words)
                    }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(self.journalIdentity.spokenValue)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("shell.pane.journal.heading")
                        .accessibilityFocused(self.$headingFocused)
                }
            }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.pane.journal")
        .onAppear { self.headingFocused = true }
        .onChange(of: self.activeWebMount, initial: true) { _, mount in
            guard self.keepsWebViewWhileReconnecting else {
                self.loadState = mount == nil ? JournalWebPresentation.connectionLostState : .loading
                return
            }
            // The journal can briefly lose its tunnel while Safari is in front.
            // Keep the same document and session storage if that origin returns.
            guard let mount, mount != self.previousWebMount else { return }
            self.loadState = .loading
            self.previousWebMount = mount
        }
        .onChange(of: self.pairingOwnerID) { _, ownerID in
            if self.previousWebMount?.ownerID != ownerID {
                self.previousWebMount = nil
            }
        }
        .onChange(of: self.appConfig.journalSendConfirmed) { _, confirmed in
            if !confirmed {
                self.reconnectLocation = JournalWebReconnectLocation()
                self.previousWebMount = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !self.appConfig.isPaired {
            ScrollView {
                // The pane's title is already the mark, so the doors don't draw it again.
                JournalSetupRoute(showsMark: false) {
                    Button {
                        if self.presentation.isPhoneModal {
                            let router = self.pairFlowRouter
                            self.dismiss()
                            Task { @MainActor in router.present(.ceremony) }
                        } else {
                            self.pairFlowRouter.present(.ceremony)
                        }
                    } label: {
                        JournalSetupPairLabel()
                    }
                    .accessibilityIdentifier("journal.alreadyHaveOne")
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch InAppJournalPresentation.content(
                journalSendConfirmed: self.appConfig.journalSendConfirmed,
                resolvedURL: self.resolvedURL,
                awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation,
                status: self.connectionSyncModel.status,
                isStalled: self.connectionStallMonitor.isStalled
            ) {
            case .web, .connectionLost:
                if let mount = self.webMount {
                    let connected = self.activeWebMount != nil
                    ZStack {
                        JournalWebView(
                            url: mount.url,
                            reloadToken: self.reloadToken,
                            navigationToken: self.pendingJournalOpen?.navigationToken ?? 0,
                            journalInstanceID: self.appConfig.deviceID,
                            pairingOwnerID: mount.ownerID,
                            reconnectLocation: self.reconnectLocation,
                            loadState: self.$loadState,
                            diagnosticLog: self.diagnosticLog,
                            importIntake: self.importIntake
                        )
                        // A changed origin, paired journal, or owner needs a new document. Navigating
                        // between paths on the same journal reuses the existing WKWebView in place,
                        // and staying mounted through a same-port reconnect keeps the document alive.
                        .id(
                            "\(JournalWebView.webViewIdentity(for: mount.url, journalInstanceID: self.appConfig.deviceID))|"
                                + "\(mount.ownerID?.uuidString ?? "")"
                        )
                        .allowsHitTesting(connected)
                        .accessibilityHidden(!connected)
                        if connected {
                            self.stateOverlay
                        } else {
                            self.waitingView
                        }
                    }
                } else {
                    self.waitingView
                }
            case .awaitingMarkConfirmation:
                VStack(spacing: 12) {
                    Text(SourceVocabulary.awaitingMarkConfirmationLine)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Text(SourceVocabulary.awaitingMarkConfirmationSubline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(SourceVocabulary.confirmTheMarkAction) {
                        self.confirmMarkTapped()
                    }
                    .buttonStyle(BrandProminentButtonStyle())
                    .accessibilityIdentifier("journal.awaitingMarkConfirmation.action")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func confirmMarkTapped() {
        let decision = AwaitingMarkConfirmationPrompt.decide(
            retrySettled: self.appConfig.retrySettleIfNeeded(),
            awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation
        )
        if decision.kickConfirmedSend {
            self.journalSendRelease?.kickConfirmedSend()
        }
        guard decision.present else { return }
        if self.presentation.isPhoneModal {
            let router = self.pairFlowRouter
            self.dismiss()
            Task { @MainActor in
                router.present(.confirmHeldJournal)
            }
        } else {
            self.pairFlowRouter.present(.confirmHeldJournal)
        }
    }

    /// No live tunnel yet: show the connection as it is rather than an error, and let
    /// the journal load on its own once the tunnel is back.
    private var waitingView: some View {
        // Only states that hold on this pane: a bare "offline" would read as the
        // phone being offline, and "connected" can't sit over a journal that isn't
        // showing yet.
        let (line, attemptInFlight): (String, Bool) = switch self.connectionSyncModel.status {
        case .connecting, .connectedIdle, .connectedWaiting, .connectedTransferring:
            (ConnectionSyncStatus.connecting.statusLine, true)
        case .waitingForHome:
            (ConnectionSyncStatus.waitingForHome.statusLine, true)
        case .reconnecting:
            (ConnectionSyncStatus.reconnecting.statusLine, true)
        case .offline, .unreachable:
            (ConnectionSyncStatus.unreachable.statusLine, false)
        }
        return VStack(spacing: 12) {
            if attemptInFlight {
                ProgressView()
            }
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("shell.pane.journal.waiting")

            if !attemptInFlight {
                Button(AppStrings.ios_migration_offline_action(), action: self.retry)
                    .buttonStyle(BrandProminentButtonStyle())
                    .accessibilityHint(AppStrings.ios_portal_attemptstoreconnecttoyourjournal())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.deckGround)
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

            Button(AppStrings.ios_migration_offline_action(), action: self.retry)
                .buttonStyle(BrandProminentButtonStyle())
                .accessibilityHint(AppStrings.ios_portal_attemptstoreconnecttoyourjournal())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.deckGround)
    }

    private func retry() {
        guard self.resolvedURL != nil else {
            if self.webMount == nil { self.loadState = JournalWebPresentation.connectionLostState }
            Task { await self.tunnelManager.retryNow() }
            return
        }
        self.reloadToken += 1
    }

}
