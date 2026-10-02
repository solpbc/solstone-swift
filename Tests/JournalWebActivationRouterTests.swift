// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WebKit
import XCTest

@MainActor
final class JournalWebActivationRouterTests: XCTestCase {
    func testOutsideNavigationCancelsAndOpensOnceDespiteReentrantCreate() async throws {
        let fixture = RouterSessionFixture()
        let requestURL = try self.url("https://example.test/private/path?day=today")
        var opened: [URL] = []
        let router = JournalWebActivationRouter(session: fixture.session) { url in
            opened.append(url)
            return true
        }
        var policy: WKNavigationActionPolicy?
        var reentrantWebView: WKWebView?

        await router.handleNavigationAction(frame: .main, request: URLRequest(url: requestURL)) { value in
            policy = value
            reentrantWebView = router.handleNewWindow(request: URLRequest(url: requestURL))
        }

        XCTAssertEqual(policy, .cancel)
        XCTAssertNil(reentrantWebView)
        XCTAssertEqual(opened, [requestURL])

        XCTAssertNil(router.handleNewWindow(request: URLRequest(url: requestURL)))
        try await self.waitFor("second window activation") { opened.count == 2 }
        XCTAssertEqual(opened, [requestURL, requestURL])

        await router.handleNavigationAction(frame: .main, request: URLRequest(url: requestURL)) { value in
            policy = value
        }
        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(opened, [requestURL, requestURL, requestURL])
        router.teardown()
        fixture.session.teardown()
    }

    func testNoTargetSameAuthorityLoadsCurrentViewOnceDespiteReentrantCreate() async throws {
        let fixture = RouterSessionFixture()
        let liveURL = try self.url("http://127.0.0.1:8080/")
        fixture.session.requestLoad(url: liveURL, reloadToken: 0)
        let initialLoadCount = fixture.loads.count
        let request = URLRequest(url: try self.url("http://127.0.0.1:8080/next"))
        let router = JournalWebActivationRouter(session: fixture.session) { _ in
            XCTFail("same-authority load must not open")
            return true
        }
        var policy: WKNavigationActionPolicy?
        var reentrantWebView: WKWebView?

        await router.handleNavigationAction(frame: .noTarget, request: request) { value in
            policy = value
            reentrantWebView = router.handleNewWindow(request: request)
        }

        XCTAssertEqual(policy, .cancel)
        XCTAssertNil(reentrantWebView)
        XCTAssertEqual(fixture.loads.count, initialLoadCount + 1)
        XCTAssertEqual(fixture.loads.last?.url, request.url)
        router.teardown()
        fixture.session.teardown()
    }

    func testSubframeExternalRequestIsAllowedWithoutOpeningOrLoading() async throws {
        let fixture = RouterSessionFixture()
        let liveURL = try self.url("http://127.0.0.1:8080/")
        fixture.session.requestLoad(url: liveURL, reloadToken: 0)
        let loadCount = fixture.loads.count
        let requestURL = try self.url("https://example.test/frame")
        var opened: [URL] = []
        let router = JournalWebActivationRouter(session: fixture.session) { url in
            opened.append(url)
            return true
        }
        var policy: WKNavigationActionPolicy?

        await router.handleNavigationAction(frame: .subframe, request: URLRequest(url: requestURL)) { value in
            policy = value
        }

        XCTAssertEqual(policy, .allow)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(fixture.loads.count, loadCount)
        router.teardown()
        fixture.session.teardown()
    }

    func testTeardownMakesNavigationAndNewWindowInert() async throws {
        let fixture = RouterSessionFixture()
        let liveURL = try self.url("http://127.0.0.1:8080/")
        fixture.session.requestLoad(url: liveURL, reloadToken: 0)
        let loadCount = fixture.loads.count
        let requestURL = try self.url("https://example.test/leave")
        var opened: [URL] = []
        let router = JournalWebActivationRouter(session: fixture.session) { url in
            opened.append(url)
            return true
        }
        router.teardown()
        var policy: WKNavigationActionPolicy?

        await router.handleNavigationAction(frame: .main, request: URLRequest(url: requestURL)) { value in
            policy = value
        }

        XCTAssertEqual(policy, .cancel)
        XCTAssertNil(router.handleNewWindow(request: URLRequest(url: requestURL)))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(fixture.loads.count, loadCount)
        fixture.session.teardown()
    }

    func testRejectedOpenLogsOnceAndPreservesLoadedState() async throws {
        let fixture = RouterSessionFixture()
        let navigation = NSObject()
        fixture.session.didStart(navigation: navigation)
        fixture.session.didFinish(navigation: navigation)
        XCTAssertEqual(fixture.states.last, .loaded)

        let requestURL = try self.url("https://example.test/private/path?secret=value")
        let router = JournalWebActivationRouter(session: fixture.session) { _ in false }
        await router.handleNavigationAction(frame: .main, request: URLRequest(url: requestURL)) { value in
            XCTAssertEqual(value, .cancel)
        }

        XCTAssertEqual(fixture.states.last, .loaded)
        let rejected = fixture.log.events.filter { $0.category == .journal && $0.message == "open_rejected" }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.detail, "generation=1")
        XCTAssertFalse(rejected.first?.detail?.contains("/private/path") ?? true)
        XCTAssertFalse(rejected.first?.detail?.contains("secret") ?? true)
        router.teardown()
        fixture.session.teardown()
    }

    func testStaleLoopbackNoTargetCancelsWithoutOpenOrLoad() async throws {
        let fixture = RouterSessionFixture()
        fixture.session.requestLoad(url: try self.url("http://127.0.0.1:8080/"), reloadToken: 0)
        let loadCount = fixture.loads.count
        let router = JournalWebActivationRouter(session: fixture.session) { _ in
            XCTFail("stale loopback must not open")
            return true
        }
        var policy: WKNavigationActionPolicy?

        await router.handleNavigationAction(
            frame: .noTarget,
            request: URLRequest(url: try self.url("http://localhost:9090/stale"))
        ) { value in
            policy = value
        }

        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(fixture.loads.count, loadCount)
        router.teardown()
        fixture.session.teardown()
    }

    private func url(_ value: String) throws -> URL {
        try XCTUnwrap(URL(string: value))
    }

    private func waitFor(_ label: String, condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

@MainActor
private final class RouterSessionFixture {
    var loads: [URLRequest] = []
    var states: [JournalWebPresentation.LoadState] = []
    let log = DiagnosticLog()
    var session: JournalWebNavigationSession!

    init() {
        self.session = JournalWebNavigationSession(
            timeout: .seconds(60),
            load: { [weak self] request in
                self?.loads.append(request)
                return nil
            },
            setState: { [weak self] state in self?.states.append(state) },
            diagnosticLog: self.log
        )
    }
}
