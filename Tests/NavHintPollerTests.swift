// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class NavHintPollerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(NavHintURLProtocol.self)
        NavHintURLProtocol.handler = nil
    }

    override func tearDown() {
        NavHintURLProtocol.handler = nil
        URLProtocol.unregisterClass(NavHintURLProtocol.self)
        super.tearDown()
    }

    @MainActor
    func testFetchDecodesHints() async {
        NavHintURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/voice/nav-hints")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "call_id")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "call-123")
            XCTAssertEqual(request.timeoutInterval, 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"hints":["today","ask"],"consumed":true}"#.utf8)
            )
        }

        let hints = await NavHintPoller().fetch(localPort: 7071, callId: "call-123")

        XCTAssertEqual(hints, ["today", "ask"])
    }

    @MainActor
    func testFetchReturnsEmptyArrayForEmptyHints() async {
        NavHintURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"hints":[],"consumed":true}"#.utf8)
            )
        }

        let hints = await NavHintPoller().fetch(localPort: 7071, callId: "call-123")

        XCTAssertEqual(hints, [])
    }

    @MainActor
    func testFetchReturnsEmptyArrayOn4xx() async {
        NavHintURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"not found"}"#.utf8)
            )
        }

        let hints = await NavHintPoller().fetch(localPort: 7071, callId: "call-123")

        XCTAssertEqual(hints, [])
    }

    @MainActor
    func testFetchReturnsEmptyArrayOnMalformedJSON() async {
        NavHintURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"bogus":true}"#.utf8)
            )
        }

        let hints = await NavHintPoller().fetch(localPort: 7071, callId: "call-123")

        XCTAssertEqual(hints, [])
    }

    @MainActor
    func testFetchReturnsEmptyArrayOnTimeout() async {
        NavHintURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let hints = await NavHintPoller().fetch(localPort: 7071, callId: "call-123")

        XCTAssertEqual(hints, [])
    }
}

private final class NavHintURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("NavHintURLProtocol handler not set")
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
