// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest
import WebKit

final class TestBridgeReceiver: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    var onMessage: (([String: Any]) -> Void)?

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            guard let self,
                  let body = message.body as? [String: Any]
            else { return }
            self.messages.append(body)
            self.onMessage?(body)
        }
    }
}

nonisolated final class BridgeIntegrationTests: XCTestCase {
    @MainActor private func makeWebView(receiver: TestBridgeReceiver) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(receiver, name: "solstone")
        return WKWebView(frame: .zero, configuration: config)
    }

    @MainActor private func loadHTML(_ html: String, in webView: WKWebView) async {
        let loaded = expectation(description: "html loaded")
        webView.loadHTMLString(html, baseURL: URL(string: "http://localhost/"))

        for _ in 0..<100 {
            if !webView.isLoading {
                loaded.fulfill()
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        await fulfillment(of: [loaded], timeout: 0.1)
    }

    @MainActor
    func testReadyMessageDelivered() async throws {
        let receiver = TestBridgeReceiver()
        let webView = self.makeWebView(receiver: receiver)
        let received = expectation(description: "ready delivered")
        var message: [String: Any]?
        receiver.onMessage = {
            message = $0
            received.fulfill()
        }

        await self.loadHTML(
            """
            <html><body><script>
            window.webkit.messageHandlers.solstone.postMessage({type: 'ready'});
            </script></body></html>
            """,
            in: webView
        )

        await fulfillment(of: [received], timeout: 5)
        let delivered = try XCTUnwrap(message)
        XCTAssertEqual(try XCTUnwrap(delivered["type"] as? String), "ready")
        XCTAssertNil(delivered["data"])
    }

    @MainActor
    func testRouteMessageDelivered() async throws {
        let receiver = TestBridgeReceiver()
        let webView = self.makeWebView(receiver: receiver)
        let received = expectation(description: "route delivered")
        var message: [String: Any]?
        receiver.onMessage = {
            message = $0
            received.fulfill()
        }

        await self.loadHTML(
            """
            <html><body><script>
            window.webkit.messageHandlers.solstone.postMessage({type: 'route', data: {route: 'ask'}});
            </script></body></html>
            """,
            in: webView
        )

        await fulfillment(of: [received], timeout: 5)
        let delivered = try XCTUnwrap(message)
        XCTAssertEqual(try XCTUnwrap(delivered["type"] as? String), "route")
        let data = try XCTUnwrap(delivered["data"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(data["route"] as? String), "ask")
    }

    @MainActor
    func testBrainMessageDelivered() async throws {
        let receiver = TestBridgeReceiver()
        let webView = self.makeWebView(receiver: receiver)
        let received = expectation(description: "brain delivered")
        var message: [String: Any]?
        receiver.onMessage = {
            message = $0
            received.fulfill()
        }

        await self.loadHTML(
            """
            <html><body><script>
            window.webkit.messageHandlers.solstone.postMessage({type: 'brain', data: {status: 'refreshing'}});
            </script></body></html>
            """,
            in: webView
        )

        await fulfillment(of: [received], timeout: 5)
        let delivered = try XCTUnwrap(message)
        XCTAssertEqual(try XCTUnwrap(delivered["type"] as? String), "brain")
        let data = try XCTUnwrap(delivered["data"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(data["status"] as? String), "refreshing")
    }

    @MainActor
    func testUnknownMessageTypeDelivered() async throws {
        let receiver = TestBridgeReceiver()
        let webView = self.makeWebView(receiver: receiver)
        let received = expectation(description: "bogus delivered")
        var message: [String: Any]?
        receiver.onMessage = {
            message = $0
            received.fulfill()
        }

        await self.loadHTML(
            """
            <html><body><script>
            window.webkit.messageHandlers.solstone.postMessage({type: 'bogus', data: {foo: 'bar'}});
            </script></body></html>
            """,
            in: webView
        )

        await fulfillment(of: [received], timeout: 5)
        let delivered = try XCTUnwrap(message)
        XCTAssertEqual(try XCTUnwrap(delivered["type"] as? String), "bogus")
        let data = try XCTUnwrap(delivered["data"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(data["foo"] as? String), "bar")
    }

    @MainActor
    func testMultipleMessagesInOrder() async {
        let receiver = TestBridgeReceiver()
        let webView = self.makeWebView(receiver: receiver)
        let received = expectation(description: "messages delivered")
        received.expectedFulfillmentCount = 3
        receiver.onMessage = { _ in
            received.fulfill()
        }

        await self.loadHTML(
            """
            <html><body><script>
            window.webkit.messageHandlers.solstone.postMessage({type: 'ready'});
            window.webkit.messageHandlers.solstone.postMessage({type: 'route', data: {route: 'ask'}});
            window.webkit.messageHandlers.solstone.postMessage({type: 'brain', data: {status: 'refreshing'}});
            </script></body></html>
            """,
            in: webView
        )

        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(receiver.messages.count, 3)
        XCTAssertEqual(receiver.messages.compactMap { $0["type"] as? String }, ["ready", "route", "brain"])
    }

    @MainActor
    func testMalformedMessageDoesNotCrash() async {
        let receiver = TestBridgeReceiver()
        let webView = self.makeWebView(receiver: receiver)
        let notReceived = expectation(description: "non-dict dropped")
        // Inverted: confirm non-dict bodies are silently dropped.
        notReceived.isInverted = true
        receiver.onMessage = { _ in
            notReceived.fulfill()
        }

        await self.loadHTML(
            """
            <html><body><script>
            window.webkit.messageHandlers.solstone.postMessage('just a string');
            </script></body></html>
            """,
            in: webView
        )

        try? await Task.sleep(nanoseconds: 500_000_000)
        await fulfillment(of: [notReceived], timeout: 0.1)
        XCTAssertTrue(receiver.messages.isEmpty)
    }
}
