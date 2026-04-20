// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class ObserverActionPollerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ObserverActionURLProtocol.self)
        ObserverActionURLProtocol.handler = nil
    }

    override func tearDown() {
        ObserverActionURLProtocol.handler = nil
        URLProtocol.unregisterClass(ObserverActionURLProtocol.self)
        super.tearDown()
    }

    func testFetchActionsDecodesStartObserver() async {
        ObserverActionURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/voice/observer-actions")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "call_id")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "call-123")
            XCTAssertEqual(request.timeoutInterval, 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"actions":[{"type":"start_observer","mode":"meeting"}],"consumed":true}"#.utf8)
            )
        }

        let actions = await ObserverActionPoller().fetchActions(localPort: 7071, callId: "call-123")

        XCTAssertEqual(actions, [.startObserver(mode: .meeting)])
    }

    func testFetchActionsReturnsEmptyArrayForEmptyActions() async {
        ObserverActionURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"actions":[],"consumed":true}"#.utf8)
            )
        }

        let actions = await ObserverActionPoller().fetchActions(localPort: 7071, callId: "call-123")

        XCTAssertEqual(actions, [])
    }

    func testFetchActionsReturnsEmptyArrayOn4xx() async {
        ObserverActionURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"not found"}"#.utf8)
            )
        }

        let actions = await ObserverActionPoller().fetchActions(localPort: 7071, callId: "call-123")

        XCTAssertEqual(actions, [])
    }

    func testFetchActionsReturnsEmptyArrayOnMalformedJSON() async {
        ObserverActionURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"bogus":true}"#.utf8)
            )
        }

        let actions = await ObserverActionPoller().fetchActions(localPort: 7071, callId: "call-123")

        XCTAssertEqual(actions, [])
    }

    func testFetchActionsReturnsEmptyArrayOnTimeout() async {
        ObserverActionURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let actions = await ObserverActionPoller().fetchActions(localPort: 7071, callId: "call-123")

        XCTAssertEqual(actions, [])
    }

    func testFetchActionsDropsUnknownActionType() async {
        ObserverActionURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"actions":[{"type":"nope","mode":"meeting"}],"consumed":true}"#.utf8)
            )
        }

        let actions = await ObserverActionPoller().fetchActions(localPort: 7071, callId: "call-123")

        XCTAssertEqual(actions, [])
    }
}

private final class ObserverActionURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("ObserverActionURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
