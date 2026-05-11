// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest
import WebKit
@testable import solstone_swift

nonisolated final class PortalPageTests: XCTestCase {
    private lazy var mockSSH = MockSSHTransport()
    private lazy var cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    @MainActor private lazy var tunnelManager = TunnelManager(transport: self.mockSSH)
    @MainActor private lazy var brainStatusMonitor = BrainStatusMonitor()
    @MainActor private lazy var mockEngine = MockPortalWebEngine()
    @MainActor private lazy var portalPage = PortalPage(
        tunnelManager: self.tunnelManager,
        brainStatusMonitor: self.brainStatusMonitor,
        cache: PortalCache(cacheDirectory: self.cacheDirectory),
        webEngine: self.mockEngine
    )

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.cacheDirectory)
        try await super.tearDown()
    }

    private func settleStageCallbacks() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }

    // Bridge-message handling (route/ready/brain) is covered in BridgeIntegrationTests.

    @MainActor
    func test_load_requestsExpectedURL() {
        self.portalPage.load(port: 7071)

        XCTAssertEqual(self.mockEngine.loadCallCount, 1)
        XCTAssertEqual(self.mockEngine.lastLoadedURL, URL(string: "http://127.0.0.1:7071/dev/mock-portal"))
    }

    @MainActor
    func test_load_resetsReadyAndCurrentRoute() {
        self.portalPage.isReady = true
        self.portalPage.currentRoute = "/old"

        self.portalPage.load(port: 7071)

        XCTAssertFalse(self.portalPage.isReady)
        XCTAssertEqual(self.portalPage.currentRoute, "")
    }

    @MainActor
    func test_load_samePortIsIdempotent() {
        self.portalPage.load(port: 7071)
        self.portalPage.load(port: 7071)

        XCTAssertEqual(self.mockEngine.loadCallCount, 1)
    }

    @MainActor
    func test_load_zeroPortIsNoop() {
        self.portalPage.load(port: 0)

        XCTAssertEqual(self.mockEngine.loadCallCount, 0)
    }

    @MainActor
    func test_navigate_emitsHashJSAndUpdatesRoute() {
        self.portalPage.navigate(to: "/foo")

        XCTAssertEqual(self.mockEngine.lastEvaluatedScript, "window.location.hash = '/foo'")
        XCTAssertEqual(self.portalPage.currentRoute, "/foo")
        XCTAssertEqual(self.mockEngine.evaluateJavaScriptCallCount, 1)
    }

    @MainActor
    func test_navigate_escapesBackslashAndSingleQuote() {
        self.portalPage.navigate(to: "a'b\\c")

        XCTAssertEqual(self.mockEngine.lastEvaluatedScript, "window.location.hash = 'a\\'b\\\\c'")
    }

    @MainActor
    func test_navigate_sameRouteIsIdempotent() {
        self.portalPage.navigate(to: "/foo")
        self.portalPage.navigate(to: "/foo")

        XCTAssertEqual(self.mockEngine.evaluateJavaScriptCallCount, 1)
    }

    @MainActor
    func test_handleNavigationFailure_loadsErrorPageForNonTunnelError() {
        self.portalPage.load(port: 7071)
        let initialLoadHTMLStringCallCount = self.mockEngine.loadHTMLStringCallCount
        let error = NSError(
            domain: "TestDomain",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "Custom 'error' & <msg>"]
        )

        self.portalPage.handleNavigationFailure(error: error, kind: "provisional")

        XCTAssertGreaterThanOrEqual(self.mockEngine.loadHTMLStringCallCount, initialLoadHTMLStringCallCount + 1)
        XCTAssertNotNil(self.mockEngine.lastLoadedHTML)
        XCTAssertTrue(self.mockEngine.lastLoadedHTML!.contains("Custom 'error' &amp; &lt;msg&gt;"))
    }

    @MainActor
    func test_load_usesCachedHTMLWhenOffline() throws {
        let cache = PortalCache(cacheDirectory: self.cacheDirectory)
        try cache.storeHTML("<html><body>cached</body></html>", path: "/dev/mock-portal")
        self.tunnelManager.forceNetworkStatus(isSatisfied: false, isWiFi: true)

        self.portalPage.load(port: 7071)

        XCTAssertEqual(self.mockEngine.loadCallCount, 0)
        XCTAssertEqual(self.mockEngine.loadHTMLStringCallCount, 1)
        XCTAssertEqual(self.mockEngine.lastLoadedBaseURL, URL(string: "http://127.0.0.1:7071/dev/mock-portal"))
        XCTAssertEqual(self.portalPage.isReady, true)
    }
}
