// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import Network
import os
import SPLTunnel
import SwiftUI
import WebKit
import XCTest

/// Runtime coverage for the production shape: loopback HTTP, a server redirect,
/// an external boot script, and an API fetch. State-machine tests cannot prove
/// that WebKit and its delegate actually carry this sequence end to end.
@MainActor
final class JournalWKWebViewRuntimeTests: XCTestCase {
    func testOpenPaneRestoresDocumentAddressAfterTunnelReconnect() async throws {
        let address = "/app/recovered/?q=a%26b#part%2F2"
        let first = try LoopbackJournalFixture(reportDocument: true, pushAddress: address)
        let firstPort = try await first.start()
        defer { first.stop() }
        let second = try LoopbackJournalFixture(reportDocument: true)
        let secondPort = try await second.start()
        defer { second.stop() }

        let confirmation = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(confirmationStore: confirmation, store: credentials)
        appConfig.seedUITestPairing(deviceID: "journal-reconnect-test")
        XCTAssertTrue(appConfig.journalSendConfirmed)

        let tunnel = TunnelManager(transport: MockCFTunnelTransport(), store: credentials)
        tunnel.forceConnected(port: Int(firstPort), via: .lan)
        let log = DiagnosticLog()
        let pane = InAppJournalView(presentation: .detail)
            .environment(appConfig)
            .environment(tunnel)
            .environment(PairFlowRouter())
            .environment(log)
            .environment(ConnectionSyncModel(clock: SystemObserverClock()) {
                ConnectionSyncInputs(
                    tunnelState: tunnel.state, reconnectCountdown: nil, isNetworkSatisfied: true,
                    confirmedTransferCount: 0, recentBytesPerSecond: 0, backlogPending: 0, backlogFailed: 0
                )
            })
            .environment(ConnectionStallMonitor(
                store: InMemoryConnectionStallStore(),
                clock: SystemConnectionStallClock(),
                credentials: credentials
            ))
        let controller = UIHostingController(rootView: pane)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let previous = try await self.waitForDocumentReport(from: first)
        XCTAssertEqual(previous.address, address)
        XCTAssertEqual(previous.title, "journal-ready")

        tunnel.forceDisconnectedForUITest()
        XCTAssertNil(tunnel.activeConnection)

        tunnel.forceConnected(port: Int(secondPort), via: .lan)
        let current = try await self.waitForDocumentReport(from: second)
        XCTAssertTrue(log.events.contains { $0.message == "teardown" })
        XCTAssertEqual(current.address, address)
        XCTAssertEqual(current.title, "journal-recovered")
        XCTAssertGreaterThan(current.timeOrigin, previous.timeOrigin)
    }

    func testOpenPanePreservesDocumentAndSessionStorageAcrossSamePortReconnect() async throws {
        let address = "/app/thinking/#byo-setup"
        let fixture = try LoopbackJournalFixture(reportDocument: true, pushAddress: address)
        let port = try await fixture.start()
        defer { fixture.stop() }

        let confirmation = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(confirmationStore: confirmation, store: credentials)
        appConfig.seedUITestPairing(deviceID: "journal-same-port-reconnect-test")

        let tunnel = TunnelManager(transport: MockCFTunnelTransport(), store: credentials)
        tunnel.forceConnected(port: Int(port), via: .lan)
        let log = DiagnosticLog()
        let pane = InAppJournalView(presentation: .detail)
            .environment(appConfig)
            .environment(tunnel)
            .environment(PairFlowRouter())
            .environment(log)
            .environment(ConnectionSyncModel(clock: SystemObserverClock()) {
                ConnectionSyncInputs(
                    tunnelState: tunnel.state, reconnectCountdown: nil, isNetworkSatisfied: true,
                    confirmedTransferCount: 0, recentBytesPerSecond: 0, backlogPending: 0, backlogFailed: 0
                )
            })
            .environment(ConnectionStallMonitor(
                store: InMemoryConnectionStallStore(),
                clock: SystemConnectionStallClock(),
                credentials: credentials
            ))
        let controller = UIHostingController(rootView: pane)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        }
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let initial = try await self.waitForDocumentReport(from: fixture)
        XCTAssertEqual(initial.address, address)
        XCTAssertEqual(initial.title, "journal-ready")

        let originalWebView = try XCTUnwrap(
            Self.findWKWebView(in: controller.view) ?? Self.findWKWebView(in: window)
        )
        _ = try await originalWebView.evaluateJavaScript("window.sessionStorage.setItem('oauth_pending', 'keep-me')")

        tunnel.forceDisconnectedForUITest()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(tunnel.activeConnection)

        tunnel.forceConnected(port: Int(port), via: .lan)
        try await Task.sleep(for: .milliseconds(100))

        let currentWebView = try XCTUnwrap(
            Self.findWKWebView(in: controller.view) ?? Self.findWKWebView(in: window)
        )
        XCTAssertTrue(currentWebView === originalWebView, "same-port reconnect must keep the existing WKWebView mounted")
        XCTAssertFalse(log.events.contains { $0.message == "teardown" })
        XCTAssertEqual(fixture.requestedPaths.filter { $0 == "/" }.count, 1)
        let stored = try await currentWebView.evaluateJavaScript("window.sessionStorage.getItem('oauth_pending')") as? String
        XCTAssertEqual(stored, "keep-me")
        let timeOrigin = try await currentWebView.evaluateJavaScript("performance.timeOrigin") as? Double
        XCTAssertEqual(timeOrigin ?? -1, initial.timeOrigin, accuracy: 0.001)
    }

    func testOpenPaneRecoversWhenSamePortReturnsAfterTransientLoadFailure() async throws {
        let probe = try LoopbackJournalFixture()
        let port = try await probe.start()
        probe.stop()
        try await Task.sleep(for: .milliseconds(100))

        let confirmation = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(confirmationStore: confirmation, store: credentials)
        appConfig.seedUITestPairing(deviceID: "journal-same-port-recovery-test")

        let tunnel = TunnelManager(transport: MockCFTunnelTransport(), store: credentials)
        tunnel.forceConnected(port: Int(port), via: .lan)
        let log = DiagnosticLog()
        let pane = InAppJournalView(presentation: .detail)
            .environment(appConfig)
            .environment(tunnel)
            .environment(PairFlowRouter())
            .environment(log)
            .environment(ConnectionSyncModel(clock: SystemObserverClock()) {
                ConnectionSyncInputs(
                    tunnelState: tunnel.state, reconnectCountdown: nil, isNetworkSatisfied: true,
                    confirmedTransferCount: 0, recentBytesPerSecond: 0, backlogPending: 0, backlogFailed: 0
                )
            })
            .environment(ConnectionStallMonitor(
                store: InMemoryConnectionStallStore(),
                clock: SystemConnectionStallClock(),
                credentials: credentials
            ))
        let controller = UIHostingController(rootView: pane)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let failureDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !log.events.contains(where: { $0.message == "failure" }) && ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(log.events.contains { $0.message == "failure" }, "initial load should fail against closed port")

        tunnel.forceDisconnectedForUITest()
        try await Task.sleep(for: .milliseconds(100))

        let recovered = try LoopbackJournalFixture(
            reportDocument: true,
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        )
        let reboundPort = try await recovered.start()
        defer { recovered.stop() }
        XCTAssertEqual(reboundPort, port)

        tunnel.forceConnected(port: Int(port), via: .lan)
        let report = try await self.waitForDocumentReport(from: recovered)
        XCTAssertEqual(report.title, "journal-ready")
    }

    private static func findWKWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }
        for subview in view.subviews {
            if let found = Self.findWKWebView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func waitForDocumentReport(from fixture: LoopbackJournalFixture) async throws -> LoopbackJournalFixture.DocumentReport {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let report = fixture.documentReport { return report }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(fixture.documentReport, "Journal did not report its document")
    }

    func testLoopbackRedirectAndBootGraphReachReadyDocument() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }

        let log = DiagnosticLog()
        var states: [JournalWebPresentation.LoadState] = []
        let coordinator = JournalWebView.Coordinator(diagnosticLog: log) { state in
            states.append(state)
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        defer {
            coordinator.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        coordinator.requestLoad(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")),
            reloadToken: 0,
            webView: webView
        )

        let title = try await self.waitForDocumentTitle("journal-ready", in: webView)
        XCTAssertEqual(title, "journal-ready")
        XCTAssertEqual(states.last, .loaded)
        XCTAssertTrue(log.events.contains { $0.category == .journal && $0.message == "redirect" })
        XCTAssertTrue(log.events.contains { $0.category == .journal && $0.message == "commit" })
        XCTAssertTrue(log.events.contains { $0.category == .journal && $0.message == "finish" })
        XCTAssertTrue(
            Set(fixture.requestedPaths).isSuperset(
                of: Set(["/", "/app/home/", "/static/boot.js", "/api/pulse"])
            ),
            "requested paths: \(fixture.requestedPaths)"
        )
    }

    func testDeletedLoopbackCookieIsRestoredForSameOriginNavigation() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }

        let log = DiagnosticLog()
        var states: [JournalWebPresentation.LoadState] = []
        let coordinator = JournalWebView.Coordinator(diagnosticLog: log) { state in
            states.append(state)
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        defer {
            coordinator.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        coordinator.requestLoad(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")),
            reloadToken: 0,
            webView: webView
        )

        let title = try await self.waitForDocumentTitle("journal-ready", in: webView)
        XCTAssertEqual(title, "journal-ready")

        await self.deleteLoopbackCookies(from: webView)

        _ = try await webView.evaluateJavaScript("window.location = '/app/recovered/'")
        let recoveredTitle = try await self.waitForDocumentTitle("journal-recovered", in: webView)
        XCTAssertEqual(recoveredTitle, "journal-recovered")

        let recoveredAdmissions = fixture.admissionsSnapshot.filter { $0.path == "/app/recovered/" }
        XCTAssertEqual(recoveredAdmissions.count, 2)
        XCTAssertEqual(recoveredAdmissions.map(\.admitted), [false, true])
    }

    func testRecoveryOfSameURLDoesNotDedupAwayTheReload() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }

        let log = DiagnosticLog()
        var states: [JournalWebPresentation.LoadState] = []
        let coordinator = JournalWebView.Coordinator(diagnosticLog: log) { state in
            states.append(state)
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        defer {
            coordinator.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        let originalURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        coordinator.requestLoad(
            url: originalURL,
            reloadToken: 0,
            webView: webView
        )

        let initialTitle = try await self.waitForDocumentTitle("journal-ready", in: webView)
        XCTAssertEqual(initialTitle, "journal-ready")

        await self.deleteLoopbackCookies(from: webView)

        _ = try await webView.evaluateJavaScript("window.location = '\(originalURL.absoluteString)'")

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var completed = false
        while clock.now < deadline {
            let admissions = fixture.admissionsSnapshot
            if let refusalIndex = admissions.firstIndex(where: { $0.path == "/" && !$0.admitted }) {
                if admissions[refusalIndex...].contains(where: { $0.path == "/api/pulse" && $0.admitted }) {
                    completed = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(completed, "recovery document did not finish booting")

        let snapshot = fixture.admissionsSnapshot
        coordinator.requestLoad(url: originalURL, reloadToken: 0, webView: webView)

        let pollDeadline = clock.now.advanced(by: .seconds(1))
        while clock.now < pollDeadline {
            XCTAssertEqual(
                fixture.admissionsSnapshot.map { "\($0.path):\($0.admitted)" },
                snapshot.map { "\($0.path):\($0.admitted)" }
            )
            try await Task.sleep(for: .milliseconds(50))
        }

        let rootAdmissions = fixture.admissionsSnapshot.filter { $0.path == "/" }
        XCTAssertEqual(rootAdmissions.count, 3)
        XCTAssertEqual(rootAdmissions.filter { !$0.admitted }.count, 1)
        XCTAssertEqual(rootAdmissions.filter { $0.admitted }.count, 2)
    }

    func testRecoveryOfDifferentURLDoesNotReplaceLatestLoad() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }

        let log = DiagnosticLog()
        var states: [JournalWebPresentation.LoadState] = []
        let coordinator = JournalWebView.Coordinator(diagnosticLog: log) { state in
            states.append(state)
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        defer {
            coordinator.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        let originalURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        coordinator.requestLoad(
            url: originalURL,
            reloadToken: 0,
            webView: webView
        )

        let initialTitle = try await self.waitForDocumentTitle("journal-ready", in: webView)
        XCTAssertEqual(initialTitle, "journal-ready")

        await self.deleteLoopbackCookies(from: webView)

        _ = try await webView.evaluateJavaScript("window.location = '/app/recovered/'")
        let recoveredTitle = try await self.waitForDocumentTitle("journal-recovered", in: webView)
        XCTAssertEqual(recoveredTitle, "journal-recovered")

        let recoveredAdmissions = fixture.admissionsSnapshot.filter { $0.path == "/app/recovered/" }
        XCTAssertEqual(recoveredAdmissions.count, 2)
        XCTAssertEqual(recoveredAdmissions.map(\.admitted), [false, true])

        let snapshot = fixture.admissionsSnapshot
        coordinator.requestLoad(url: originalURL, reloadToken: 0, webView: webView)

        let clock = ContinuousClock()
        let pollDeadline = clock.now.advanced(by: .seconds(1))
        while clock.now < pollDeadline {
            XCTAssertEqual(
                fixture.admissionsSnapshot.map { "\($0.path):\($0.admitted)" },
                snapshot.map { "\($0.path):\($0.admitted)" }
            )
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func deleteLoopbackCookies(from webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies where cookie.name == LoopbackCapability.cookieName {
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    func testExternalLocationActivationsAreHandedOffWithoutLoadFailure() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let recorder = RuntimeJournalRecorder()
        let journal = try await self.makeJournal(port: port, recorder: recorder)
        defer { journal.teardown() }

        _ = try await journal.webView.evaluateJavaScript("window.location = 'https://example.test/script'")
        try await self.waitForOpenCount(1, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs, [try XCTUnwrap(URL(string: "https://example.test/script"))])

        _ = try await journal.webView.evaluateJavaScript(
            "setTimeout(function(){ window.location = 'https://example.test/delayed'; }, 0)"
        )
        try await self.waitForOpenCount(2, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs[1], try XCTUnwrap(URL(string: "https://example.test/delayed")))

        let repeatedURL = try XCTUnwrap(URL(string: "https://example.test/repeat"))
        _ = try await journal.webView.evaluateJavaScript(
            "window.location = 'https://example.test/repeat'; " +
                "setTimeout(function(){ window.location = 'https://example.test/repeat'; }, 150)"
        )
        try await self.waitForOpenCount(4, recorder: recorder)
        XCTAssertEqual(Array(recorder.openedURLs.suffix(2)), [repeatedURL, repeatedURL])

        let title = try await self.waitForDocumentTitle("journal-ready", in: journal.webView)
        XCTAssertEqual(title, "journal-ready")
        XCTAssertFalse(recorder.states.contains { state in
            if case .error(message: JournalWebPresentation.loadFailureMessage) = state { return true }
            return false
        })
    }

    func testRedirectToExternalAuthorityOpensWithoutCommittingForeignURL() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let recorder = RuntimeJournalRecorder()
        let journal = try await self.makeJournal(port: port, recorder: recorder)
        defer { journal.teardown() }
        let foreignURL = try XCTUnwrap(URL(string: "https://example.test/foreign"))

        _ = try await journal.webView.evaluateJavaScript("window.location = '/redirect-foreign'")
        try await self.waitForOpenCount(1, recorder: recorder)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(recorder.openedURLs, [foreignURL])
        XCTAssertNotEqual(journal.webView.url, foreignURL)
        let title = try await self.waitForDocumentTitle("journal-ready", in: journal.webView)
        XCTAssertEqual(title, "journal-ready")
        XCTAssertFalse(fixture.requestedPaths.contains("/foreign"))
    }

    func testBlankTargetAndWindowOpenHandoffAndSameAuthorityLoad() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let recorder = RuntimeJournalRecorder()
        let journal = try await self.makeJournal(
            port: port,
            recorder: recorder,
            allowsJavaScriptWindows: true
        )
        defer { journal.teardown() }

        _ = try await journal.webView.evaluateJavaScript("document.getElementById('blank').click()")
        try await self.waitForOpenCount(1, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs, [try XCTUnwrap(URL(string: "https://example.test/blank"))])

        _ = try await journal.webView.evaluateJavaScript("document.getElementById('blank').click()")
        try await self.waitForOpenCount(2, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs.count, 2)

        _ = try await journal.webView.evaluateJavaScript("window.open('https://example.test/open')")
        try await self.waitForOpenCount(3, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs[2], try XCTUnwrap(URL(string: "https://example.test/open")))

        _ = try await journal.webView.evaluateJavaScript("document.getElementById('same').click()")
        let title = try await self.waitForDocumentTitle("same-authority-target", in: journal.webView)
        XCTAssertEqual(title, "same-authority-target")
        XCTAssertEqual(recorder.openedURLs.count, 3)
    }

    func testConfirmAndPromptDrawAPanelAndAnswerWhatTheOwnerChose() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let journal = try await self.makeJournal(port: port, recorder: RuntimeJournalRecorder())
        defer { journal.teardown() }
        let panels = journal.coordinator.panels

        let confirmed = Task { try await journal.webView.evaluateJavaScript("confirm('unpair this device?')") as? Bool }
        let confirmPanel = try await self.waitForOpenPanel(panels)
        XCTAssertEqual(confirmPanel.message, "unpair this device?")
        XCTAssertNotNil(confirmPanel.presentingViewController)
        XCTAssertEqual(confirmPanel.actions.map(\.title), ["cancel", "ok"])
        panels.answer(accepted: false)
        let declined = try await confirmed.value
        XCTAssertEqual(declined, false)

        let accepted = Task { try await journal.webView.evaluateJavaScript("confirm('unpair this device?')") as? Bool }
        _ = try await self.waitForOpenPanel(panels)
        panels.answer(accepted: true)
        let acceptedValue = try await accepted.value
        XCTAssertEqual(acceptedValue, true)

        let renamed = Task { try await journal.webView.evaluateJavaScript("prompt('rename this key', 'old name')") as? String }
        let promptPanel = try await self.waitForOpenPanel(panels)
        XCTAssertEqual(promptPanel.message, "rename this key")
        XCTAssertEqual(promptPanel.textFields?.first?.text, "old name")
        promptPanel.textFields?.first?.text = "laptop"
        panels.answer(accepted: true)
        let newName = try await renamed.value
        XCTAssertEqual(newName, "laptop")
    }

    func testAPanelOpenWhenThePaneClosesAnswersCancel() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let journal = try await self.makeJournal(port: port, recorder: RuntimeJournalRecorder())
        defer { journal.teardown() }

        let confirmed = Task { try await journal.webView.evaluateJavaScript("confirm('unpair this device?')") as? Bool }
        _ = try await self.waitForOpenPanel(journal.coordinator.panels)
        journal.coordinator.teardown()
        let answer = try await confirmed.value
        XCTAssertEqual(answer, false)
        XCTAssertNil(journal.coordinator.panels.openAlert)
    }

    private func waitForOpenPanel(_ panels: JournalWebPanels) async throws -> UIAlertController {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if let alert = panels.openAlert { return alert }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(panels.openAlert, "no panel opened")
    }

    private func makeJournal(
        port: UInt16,
        recorder: RuntimeJournalRecorder,
        allowsJavaScriptWindows: Bool = false
    ) async throws -> RuntimeJournal {
        let diagnosticLog = DiagnosticLog()
        let coordinator = JournalWebView.Coordinator(
            diagnosticLog: diagnosticLog,
            setState: { recorder.states.append($0) },
            opener: { url in
                recorder.openedURLs.append(url)
                return true
            }
        )
        let configuration = JournalWebHostContractConfiguration.make(diagnosticLog: diagnosticLog)
        if allowsJavaScriptWindows {
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        webView.frame = window.bounds
        root.view.addSubview(webView)
        window.makeKeyAndVisible()
        coordinator.observeForeground(of: webView)
        coordinator.requestLoad(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")),
            reloadToken: 0,
            webView: webView
        )
        _ = try await self.waitForDocumentTitle("journal-ready", in: webView)
        return RuntimeJournal(webView: webView, window: window, coordinator: coordinator)
    }

    private func waitForOpenCount(_ expected: Int, recorder: RuntimeJournalRecorder) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if recorder.openedURLs.count >= expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("expected \(expected) external opens, got \(recorder.openedURLs.count)")
    }

    private func waitForDocumentTitle(_ expected: String, in webView: WKWebView) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var lastTitle: String?
        while clock.now < deadline {
            lastTitle = try await webView.evaluateJavaScript("document.title") as? String
            if lastTitle == expected {
                return lastTitle
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("document title did not become \(expected); last=\(lastTitle ?? "nil")")
        return lastTitle
    }
}

@MainActor
private final class RuntimeJournalRecorder {
    var states: [JournalWebPresentation.LoadState] = []
    var openedURLs: [URL] = []
}

@MainActor
private struct RuntimeJournal {
    let webView: WKWebView
    let window: UIWindow
    let coordinator: JournalWebView.Coordinator

    func teardown() {
        self.coordinator.teardown()
        self.webView.stopLoading()
        self.webView.navigationDelegate = nil
        self.webView.uiDelegate = nil
        self.window.isHidden = true
    }
}

private final class LoopbackJournalFixture: @unchecked Sendable {
    struct DocumentReport: Sendable {
        let address: String
        let title: String
        let timeOrigin: Double
    }

    private let listener: NWListener
    private let reportDocument: Bool
    private let pushAddress: String?
    private let queue = DispatchQueue(label: "app.solstone.swift.tests.journal-loopback")
    private let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let admissions = OSAllocatedUnfairLock<[(path: String, admitted: Bool)]>(initialState: [])
    private let startup = OSAllocatedUnfairLock<CheckedContinuation<UInt16, any Error>?>(initialState: nil)
    private let report = OSAllocatedUnfairLock<DocumentReport?>(initialState: nil)

    var documentReport: DocumentReport? {
        self.report.withLock { $0 }
    }

    var requestedPaths: [String] {
        self.paths.withLock { $0 }
    }

    var admissionsSnapshot: [(path: String, admitted: Bool)] {
        self.admissions.withLock { $0 }
    }

    init(reportDocument: Bool = false, pushAddress: String? = nil, port: NWEndpoint.Port = .any) throws {
        self.reportDocument = reportDocument
        self.pushAddress = pushAddress
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        self.listener = try NWListener(using: parameters)
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else {
                    self.resumeStartup(throwing: FixtureError.missingPort)
                    return
                }
                self.resumeStartup(returning: port.rawValue)
            case .failed(let error):
                self.resumeStartup(throwing: error)
            default:
                break
            }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            self.startup.withLock { $0 = continuation }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() {
        self.listener.cancel()
    }

    private func resumeStartup(returning port: UInt16) {
        let continuation = self.startup.withLock { continuation -> CheckedContinuation<UInt16, any Error>? in
            let value = continuation
            continuation = nil
            return value
        }
        continuation?.resume(returning: port)
    }

    private func resumeStartup(throwing error: any Error) {
        let continuation = self.startup.withLock { continuation -> CheckedContinuation<UInt16, any Error>? in
            let value = continuation
            continuation = nil
            return value
        }
        continuation?.resume(throwing: error)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: self.queue)
        self.receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = accumulated
            if let data {
                requestData.append(data)
            }
            let headersComplete = requestData.range(of: Data("\r\n\r\n".utf8)) != nil
            if !headersComplete, error == nil, !isComplete {
                self.receiveRequest(on: connection, accumulated: requestData)
                return
            }
            guard error == nil,
                  let request = String(data: requestData, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first,
                  firstLine.hasPrefix("GET ")
            else {
                connection.cancel()
                return
            }
            let target = firstLine.split(separator: " ")[1]
            let path = String(target.split(separator: "?", maxSplits: 1)[0])
            self.paths.withLock { $0.append(path) }

            let admitted = Self.hasCapabilityCookie(in: request)
            self.admissions.withLock { $0.append((path: path, admitted: admitted)) }

            if !admitted {
                let body = "refused: this connection is missing the solstone app's local secret\n"
                let refusalResponse = "HTTP/1.1 403 Forbidden\r\n"
                    + "Content-Type: text/plain; charset=utf-8\r\n"
                    + "X-SPL-Loopback-Refused: missing\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n"
                    + body
                connection.send(content: Data(refusalResponse.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            if path == "/test-document",
               let query = URLComponents(string: String(target))?.queryItems,
               let address = query.first(where: { $0.name == "address" })?.value,
               let title = query.first(where: { $0.name == "title" })?.value,
               let timeText = query.first(where: { $0.name == "time" })?.value,
               let time = Double(timeText)
            {
                self.report.withLock { $0 = DocumentReport(address: address, title: title, timeOrigin: time) }
            }
            let response = self.response(for: path)
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func hasCapabilityCookie(in request: String) -> Bool {
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "cookie"
            else { continue }
            for pair in line[line.index(after: colon)...].split(separator: ";") {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                if trimmed == LoopbackCapability.process.cookieHeaderValue {
                    return true
                }
            }
        }
        return false
    }

    private func response(for path: String) -> String {
        let reportScript = self.reportDocument ? """
        fetch('/test-document?' + new URLSearchParams({
            address: location.pathname + location.search + location.hash,
            title: document.title, time: performance.timeOrigin
        }));
        """ : ""
        switch path {
        case "/":
            return Self.httpResponse(status: "302 Found", headers: ["Location: /app/home/"], body: "")
        case "/app/recovered/":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: text/html; charset=utf-8"],
                body: "<!doctype html><html><head><title>journal-recovered</title></head><body>recovered<script>\(reportScript)</script></body></html>"
            )
        case "/app/home/":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: text/html; charset=utf-8"],
                body: """
                <!doctype html><html><head><title>journal-loading</title></head>
                <body><main id="surface">loading</main>
                <a id="blank" target="_blank" href="https://example.test/blank">outside</a>
                <a id="same" target="_blank" href="/same-authority-target">same authority</a>
                <script src="/static/boot.js"></script></body></html>
                """
            )
        case "/redirect-foreign":
            return Self.httpResponse(status: "302 Found", headers: ["Location: https://example.test/foreign"], body: "")
        case "/same-authority-target":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: text/html; charset=utf-8"],
                body: "<!doctype html><html><head><title>same-authority-target</title></head><body>same</body></html>"
            )
        case "/static/boot.js":
            let push = self.pushAddress.map { "history.pushState(null, '', '\($0)');" } ?? ""
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: application/javascript"],
                body: """
                fetch('/api/pulse').then(r => r.json()).then(() => {
                    document.title = 'journal-ready';
                    \(push)
                    \(reportScript)
                });
                """
            )
        case "/test-document":
            return Self.httpResponse(status: "204 No Content", headers: [], body: "")
        case "/api/pulse":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: application/json"],
                body: "{\"ok\":true}"
            )
        default:
            return Self.httpResponse(status: "404 Not Found", headers: [], body: "not found")
        }
    }

    private static func httpResponse(status: String, headers: [String], body: String) -> String {
        let common = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
        ] + headers
        return common.joined(separator: "\r\n") + "\r\n\r\n" + body
    }
}

private enum FixtureError: Error {
    case missingPort
}
