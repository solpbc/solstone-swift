// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AuthenticationServices
import Foundation
import WebKit
import XCTest

@MainActor
private final class FakeAuthSessionHandle: JournalAuthSessionHandle {
    var cancelled = false
    func cancel() { self.cancelled = true }
}

@MainActor
private final class FakeAuthSessionRunner: JournalAuthSessionRunning {
    struct Launch {
        let url: URL
        let callbackScheme: String
        let handle: FakeAuthSessionHandle
        let onCallback: @MainActor (URL) -> Bool
        let onClosed: @MainActor (JournalAuthSessionFailure) -> Void
    }

    var launches: [Launch] = []
    var failStart = false

    func start(
        url: URL,
        callbackScheme: String,
        anchorProvider: @escaping @MainActor () -> ASPresentationAnchor?,
        onCallback: @escaping @MainActor (URL) -> Bool,
        onClosed: @escaping @MainActor (JournalAuthSessionFailure) -> Void
    ) -> (any JournalAuthSessionHandle)? {
        if self.failStart { return nil }
        let handle = FakeAuthSessionHandle()
        self.launches.append(Launch(
            url: url,
            callbackScheme: callbackScheme,
            handle: handle,
            onCallback: onCallback,
            onClosed: onClosed
        ))
        return handle
    }
}

@MainActor
private final class NoOpAuthImportIntake: JournalImportIntake {
    func take(_ providers: [any ShareItemProvider], names: [String], handoff: ShareImportHandoff) async -> JournalImportIntakeResult {
        JournalImportIntakeResult()
    }

    func state(of item: UUID) async -> JournalImportItemState { .gone }
}

@MainActor
final class JournalAuthHostTests: XCTestCase {
    private let entryURL = URL(string: "http://127.0.0.1:54321/")!
    private let documentID = UUID().uuidString.lowercased()

    func testPackagedAuthContractAndInfoPlistSchemes() throws {
        let loaded = try XCTUnwrap(JournalAuthHostContract.load())
        XCTAssertEqual(loaded.contract.version, 2)
        XCTAssertEqual(loaded.contract.capability, "solstoneJournalHost")
        XCTAssertEqual(loaded.contract.prepare, "auth.prepare")
        XCTAssertEqual(loaded.contract.prepared, "auth.prepared")
        XCTAssertEqual(loaded.contract.authorize, "auth.authorize")
        XCTAssertEqual(loaded.contract.cancel, "auth.cancel")
        XCTAssertEqual(loaded.contract.result, "auth.result")
        XCTAssertEqual(loaded.contract.unsupported, "unsupported")

        let urlTypes = Bundle(for: AppDelegate.self).object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = Set(urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        XCTAssertTrue(schemes.contains("solstone"))
        XCTAssertTrue(schemes.contains("app.solstone"))
    }

    func testHappyPathSolstoneAndAppSolstoneCustomSchemesAndNonConsumingRefusal() async throws {
        let runner = FakeAuthSessionRunner()
        let host = try self.makeHost(runner: runner)

        // 1. solstone://oauth/callback (with loopback ahead in preferences, skipped on mobile)
        let prep1 = try await self.send([
            "type": "auth.prepare",
            "id": "prep-1",
            "preferences": [
                ["mode": "loopback", "host": "127.0.0.1", "path": "/auth/callback", "port": 0],
                ["mode": "custom_scheme", "uri": "solstone://oauth/callback"],
                ["mode": "custom_scheme", "uri": "app.solstone:/callback"],
            ],
        ], to: host)
        XCTAssertEqual(prep1["type"] as? String, "auth.prepared")
        XCTAssertEqual(prep1["id"] as? String, "prep-1")
        XCTAssertEqual(prep1["outcome"] as? String, "ready")
        XCTAssertEqual(prep1["mode"] as? String, "custom_scheme")
        XCTAssertEqual(prep1["redirect_uri"] as? String, "solstone://oauth/callback")
        let sid1 = try XCTUnwrap(prep1["session_id"] as? String)

        let authPacket1 = try self.packet([
            "type": "auth.authorize",
            "id": "auth-1",
            "session_id": sid1,
            "authorize_url": "https://mcp.plaud.ai/authorize?client_id=test",
            "expected_state": "state_ios_1",
            "timeout_seconds": 60,
        ])
        let pending1 = Task { try await host.handle(packet: authPacket1).get() }
        while runner.launches.isEmpty { await Task.yield() }
        let launch1 = try XCTUnwrap(runner.launches.last)
        XCTAssertEqual(launch1.callbackScheme, "solstone")
        XCTAssertEqual(launch1.url.absoluteString, "https://mcp.plaud.ai/authorize?client_id=test")

        // Mismatched host, path, scheme, duplicate query, and wrong state must all be refused
        // WITHOUT consuming the active session.
        XCTAssertFalse(launch1.onCallback(URL(string: "solstone://other/callback?code=c1&state=state_ios_1")!))
        XCTAssertFalse(launch1.onCallback(URL(string: "solstone://oauth/other?code=c1&state=state_ios_1")!))
        XCTAssertFalse(launch1.onCallback(URL(string: "app.solstone:/callback?code=c1&state=state_ios_1")!))
        XCTAssertFalse(launch1.onCallback(URL(string: "solstone://oauth/callback?code=c1&state=state_ios_1&state=dup")!))
        XCTAssertFalse(launch1.onCallback(URL(string: "solstone://oauth/callback?code=c1&state=wrong_state")!))
        XCTAssertFalse(launch1.handle.cancelled)

        // Exact scheme + host + path + state succeeds.
        XCTAssertTrue(launch1.onCallback(URL(string: "solstone://oauth/callback?code=good_code&state=state_ios_1")!))
        let result1 = try self.object(try await pending1.value)
        XCTAssertEqual(result1["type"] as? String, "auth.result")
        XCTAssertEqual(result1["id"] as? String, "auth-1")
        XCTAssertEqual(result1["outcome"] as? String, "callback")
        XCTAssertEqual(result1["callback_url"] as? String, "solstone://oauth/callback?code=good_code&state=state_ios_1")

        // 2. app.solstone:/callback (hostless ATProto custom scheme)
        let prep2 = try await self.send([
            "type": "auth.prepare",
            "id": "prep-2",
            "preferences": [
                ["mode": "custom_scheme", "uri": "app.solstone:/callback"],
            ],
        ], to: host)
        XCTAssertEqual(prep2["outcome"] as? String, "ready")
        XCTAssertEqual(prep2["redirect_uri"] as? String, "app.solstone:/callback")
        let sid2 = try XCTUnwrap(prep2["session_id"] as? String)

        let authPacket2 = try self.packet([
            "type": "auth.authorize",
            "id": "auth-2",
            "session_id": sid2,
            "authorize_url": "https://bsky.social/oauth/authorize?request_uri=urn:x",
            "expected_state": "state_atproto_2",
        ])
        let pending2 = Task { try await host.handle(packet: authPacket2).get() }
        while runner.launches.count < 2 { await Task.yield() }
        let launch2 = try XCTUnwrap(runner.launches.last)
        XCTAssertEqual(launch2.callbackScheme, "app.solstone")

        // Reject host-bearing app.solstone://evil/callback and wrong path.
        XCTAssertFalse(launch2.onCallback(URL(string: "app.solstone://evil/callback?code=c2&state=state_atproto_2")!))
        XCTAssertFalse(launch2.onCallback(URL(string: "app.solstone:/other?code=c2&state=state_atproto_2")!))
        XCTAssertTrue(launch2.onCallback(URL(string: "app.solstone:/callback?code=c2&state=state_atproto_2")!))

        let result2 = try self.object(try await pending2.value)
        XCTAssertEqual(result2["outcome"] as? String, "callback")
        XCTAssertEqual(result2["callback_url"] as? String, "app.solstone:/callback?code=c2&state=state_atproto_2")
    }

    func testLoopbackOnlyPreferenceReturnsNoCompatibleModeAndArbitrarySchemesAreRejected() async throws {
        let host = try self.makeHost(runner: FakeAuthSessionRunner())

        let loopbackOnly = try await self.send([
            "type": "auth.prepare",
            "id": "prep-lb",
            "preferences": [
                ["mode": "loopback", "host": "127.0.0.1", "path": "/auth/callback", "port": 0],
            ],
        ], to: host)
        XCTAssertEqual(loopbackOnly["type"] as? String, "auth.prepared")
        XCTAssertEqual(loopbackOnly["id"] as? String, "prep-lb")
        XCTAssertEqual(loopbackOnly["outcome"] as? String, "no_compatible_mode")

        let arbitraryScheme = try await self.send([
            "type": "auth.prepare",
            "id": "prep-evil",
            "preferences": [
                ["mode": "custom_scheme", "uri": "evil://oauth/callback"],
            ],
        ], to: host)
        XCTAssertEqual(arbitraryScheme["outcome"] as? String, "no_compatible_mode")
    }

    func testInvalidAuthorizeURLStateAndSessionAreRefusedWithoutLaunchingSheet() async throws {
        let runner = FakeAuthSessionRunner()
        let host = try self.makeHost(runner: runner)

        let prep = try await self.send([
            "type": "auth.prepare",
            "id": "prep-val",
            "preferences": [["mode": "custom_scheme", "uri": "solstone://oauth/callback"]],
        ], to: host)
        let sid = try XCTUnwrap(prep["session_id"] as? String)

        for badURL in [
            "http://provider.example/auth",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,hi",
            "https://user:pass@provider.example/auth",
            "https://user@provider.example/auth",
            "https://provider.example/a b",
            "https://provider.example/" + String(repeating: "a", count: 8200),
            "",
        ] {
            let reply = try await self.send([
                "type": "auth.authorize",
                "id": "bad-url",
                "session_id": sid,
                "authorize_url": badURL,
                "expected_state": "valid_state",
            ], to: host)
            XCTAssertEqual(reply["type"] as? String, "auth.result")
            XCTAssertEqual(reply["outcome"] as? String, "refused")
        }

        let badState = try await self.send([
            "type": "auth.authorize",
            "id": "bad-state",
            "session_id": sid,
            "authorize_url": "https://provider.example/auth",
            "expected_state": "bad state with spaces",
        ], to: host)
        XCTAssertEqual(badState["outcome"] as? String, "refused")

        let badSession = try await self.send([
            "type": "auth.authorize",
            "id": "bad-sess",
            "session_id": "unknown-session",
            "authorize_url": "https://provider.example/auth",
            "expected_state": "valid_state",
        ], to: host)
        XCTAssertEqual(badSession["outcome"] as? String, "refused")

        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testCancelSupersedingPrepareDocumentNavigationTeardownAndTimeoutSettleAuthorize() async throws {
        let runner = FakeAuthSessionRunner()
        let host = try self.makeHost(runner: runner)

        // 1. Explicit auth.cancel
        let prep1 = try await self.send([
            "type": "auth.prepare", "id": "p1",
            "preferences": [["mode": "custom_scheme", "uri": "solstone://oauth/callback"]],
        ], to: host)
        let sid1 = try XCTUnwrap(prep1["session_id"] as? String)
        let authPkt1 = try self.packet([
            "type": "auth.authorize", "id": "a1", "session_id": sid1,
            "authorize_url": "https://provider.example/auth", "expected_state": "st1",
        ])
        let task1 = Task { try await host.handle(packet: authPkt1).get() }
        while runner.launches.count < 1 { await Task.yield() }

        let cancelReply = try await self.send(["type": "auth.cancel", "id": "c1", "session_id": sid1], to: host)
        XCTAssertEqual(cancelReply["type"] as? String, "auth.result")
        XCTAssertEqual(cancelReply["id"] as? String, "c1")
        XCTAssertEqual(cancelReply["outcome"] as? String, "cancelled")
        let res1 = try self.object(try await task1.value)
        XCTAssertEqual(res1["id"] as? String, "a1")
        XCTAssertEqual(res1["outcome"] as? String, "cancelled")
        XCTAssertTrue(runner.launches[0].handle.cancelled)

        // 2. Superseding auth.prepare settles in-flight authorize as cancelled
        let prep2 = try await self.send([
            "type": "auth.prepare", "id": "p2",
            "preferences": [["mode": "custom_scheme", "uri": "solstone://oauth/callback"]],
        ], to: host)
        let sid2 = try XCTUnwrap(prep2["session_id"] as? String)
        let authPkt2 = try self.packet([
            "type": "auth.authorize", "id": "a2", "session_id": sid2,
            "authorize_url": "https://provider.example/auth", "expected_state": "st2",
        ])
        let task2 = Task { try await host.handle(packet: authPkt2).get() }
        while runner.launches.count < 2 { await Task.yield() }

        let prep3 = try await self.send([
            "type": "auth.prepare", "id": "p3",
            "preferences": [["mode": "custom_scheme", "uri": "app.solstone:/callback"]],
        ], to: host)
        XCTAssertEqual(prep3["outcome"] as? String, "ready")
        let res2 = try self.object(try await task2.value)
        XCTAssertEqual(res2["id"] as? String, "a2")
        XCTAssertEqual(res2["outcome"] as? String, "cancelled")
        XCTAssertTrue(runner.launches[1].handle.cancelled)

        // 3. Document change (new documentId) settles in-flight authorize as cancelled
        let sid3 = try XCTUnwrap(prep3["session_id"] as? String)
        let authPkt3 = try self.packet([
            "type": "auth.authorize", "id": "a3", "session_id": sid3,
            "authorize_url": "https://provider.example/auth", "expected_state": "st3",
        ])
        let task3 = Task { try await host.handle(packet: authPkt3).get() }
        while runner.launches.count < 3 { await Task.yield() }

        let nextDoc = try JSONSerialization.data(withJSONObject: [
            "documentId": UUID().uuidString.lowercased(),
            "message": ["type": "host.ready"],
        ])
        _ = try await host.handle(packet: String(decoding: nextDoc, as: UTF8.self)).get()
        let res3 = try self.object(try await task3.value)
        XCTAssertEqual(res3["id"] as? String, "a3")
        XCTAssertEqual(res3["outcome"] as? String, "cancelled")
        XCTAssertTrue(runner.launches[2].handle.cancelled)

        // 4. Timeout settles in-flight authorize as timeout
        let prep4 = try await self.send([
            "type": "auth.prepare", "id": "p4",
            "preferences": [["mode": "custom_scheme", "uri": "solstone://oauth/callback"]],
        ], to: host)
        let sid4 = try XCTUnwrap(prep4["session_id"] as? String)
        let res4 = try await self.send([
            "type": "auth.authorize", "id": "a4", "session_id": sid4,
            "authorize_url": "https://provider.example/auth", "expected_state": "st4",
            "timeout_seconds": 1,
        ], to: host)
        XCTAssertEqual(res4["id"] as? String, "a4")
        XCTAssertEqual(res4["outcome"] as? String, "timeout")
        XCTAssertTrue(runner.launches[3].handle.cancelled)
    }

    func testWebViewRoundTripPreservesOpenWebViewAndEnforcesTopFrameOriginIsolation() async throws {
        let runner = FakeAuthSessionRunner()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let host = try self.makeHost(runner: runner)
        host.install(in: configuration.userContentController)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        host.attach(to: webView)
        defer { host.teardown(controller: configuration.userContentController) }

        try await self.load(
            #"<!doctype html><title>journal</title><iframe srcdoc="<p>sub</p>"></iframe>"#,
            baseURL: self.entryURL,
            in: webView
        )

        // Happy path through real window.solstoneJournalHost.send() inside live WKWebView.
        let prepJSON = try await webView.callAsyncJavaScript(
            """
            const r = await window.solstoneJournalHost.send({
              type: 'auth.prepare',
              id: 'wv-prep',
              preferences: [
                { mode: 'loopback', host: '127.0.0.1', path: '/cb', port: 0 },
                { mode: 'custom_scheme', uri: 'solstone://oauth/callback' }
              ]
            });
            return JSON.stringify(r);
            """,
            contentWorld: .page
        ) as? String
        let prep = try self.object(try XCTUnwrap(prepJSON))
        XCTAssertEqual(prep["outcome"] as? String, "ready")
        let sessionID = try XCTUnwrap(prep["session_id"] as? String)

        let jsAuthTask = Task {
            try await webView.callAsyncJavaScript(
                """
                const r = await window.solstoneJournalHost.send({
                  type: 'auth.authorize',
                  id: 'wv-auth',
                  session_id: sid,
                  authorize_url: 'https://mcp.plaud.ai/authorize',
                  expected_state: 'wv_state'
                });
                return JSON.stringify(r);
                """,
                arguments: ["sid": sessionID],
                contentWorld: .page
            ) as? String
        }
        while runner.launches.isEmpty { await Task.yield() }
        XCTAssertTrue(runner.launches[0].onCallback(URL(string: "solstone://oauth/callback?code=wv_code&state=wv_state")!))
        let authJSON = try await jsAuthTask.value
        let authReply = try self.object(try XCTUnwrap(authJSON))
        XCTAssertEqual(authReply["outcome"] as? String, "callback")
        XCTAssertEqual(authReply["callback_url"] as? String, "solstone://oauth/callback?code=wv_code&state=wv_state")

        // Subframe cannot send auth.prepare.
        let subframeResult = try await webView.callAsyncJavaScript(
            """
            const frame = document.querySelector('iframe').contentWindow;
            try {
              await frame.webkit.messageHandlers.journalImport.postMessage(JSON.stringify({
                documentId: frame.crypto.randomUUID(),
                message: { type: 'auth.prepare', id: 'sf', preferences: [{ mode: 'custom_scheme', uri: 'solstone://oauth/callback' }] }
              }));
              return 'answered';
            } catch (_) { return 'refused'; }
            """,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(subframeResult, "refused")
    }

    func testStrayOAuthCallbackURLIsIgnoredByExternalPairLinkIntake() {
        let handoff = PairingHandoffState()
        let confirmation = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation, loadPairing: { nil }, savePairing: { _ in }, deletePairing: {}
        )
        let appConfig = AppConfig(confirmationStore: confirmation, store: credentials)
        let pendingJournal = PendingJournalOpenState()
        for raw in [
            "solstone://oauth/callback?code=stray&state=wrong",
            "app.solstone:/callback?code=stray&state=wrong",
        ] {
            ExternalPairLinkIntake.handle(
                url: URL(string: raw)!,
                pairingHandoff: handoff,
                appConfig: appConfig,
                pendingJournalOpen: pendingJournal
            )
            XCTAssertNil(handoff.stagedDraft)
            XCTAssertNil(handoff.pairURLError)
            XCTAssertFalse(pendingJournal.showsInvalidLinkNotice)
        }
    }

    // MARK: - Helpers

    private func makeHost(runner: FakeAuthSessionRunner) throws -> JournalImportHost {
        try XCTUnwrap(JournalImportHost(
            entryURL: self.entryURL,
            intake: NoOpAuthImportIntake(),
            authRunner: runner
        ))
    }

    private func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        webView.loadHTMLString(html, baseURL: baseURL)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading,
               (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete" {
                return
            }
        }
        XCTFail("page did not load")
    }

    private func send(_ message: [String: Any], to host: JournalImportHost) async throws -> [String: Any] {
        try self.object(try await host.handle(packet: try self.packet(message)).get())
    }

    private func packet(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["documentId": self.documentID, "message": message])
        return String(decoding: data, as: UTF8.self)
    }

    private func object(_ reply: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }
}
