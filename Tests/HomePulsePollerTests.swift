// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class HomePulsePollerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(HomePulseURLProtocol.self)
        HomePulseURLProtocol.handler = nil
    }

    override func tearDown() {
        HomePulseURLProtocol.handler = nil
        URLProtocol.unregisterClass(HomePulseURLProtocol.self)
        super.tearDown()
    }

    @MainActor
    func testFetchDecodesWelcomeFraming() async {
        HomePulseURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/home/api/pulse")
            XCTAssertEqual(request.timeoutInterval, 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"""
                    {
                      "journal_age_days": 9,
                      "home_state": "warming",
                      "welcome_framing": "your journal is just getting its bearings",
                      "needs": ["more days"],
                      "progress": {"today": 2},
                      "narrative": "quiet start",
                      "briefing": {"ready": false}
                    }
                    """#.utf8
                )
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertEqual(framing, "your journal is just getting its bearings")
    }

    @MainActor
    func testFetchReturnsNilForNullFraming() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"journal_age_days":1,"home_state":"warming","welcome_framing":null}"#.utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilForAbsentFraming() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"journal_age_days":1,"home_state":"warming"}"#.utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilForEmptyFraming() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"journal_age_days":1,"home_state":"warming","welcome_framing":""}"#.utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilForWhitespaceFraming() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"journal_age_days":1,"home_state":"warming","welcome_framing":"   \n  "}"#.utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilForWrongTypeFramingNumber() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"journal_age_days":1,"home_state":"warming","welcome_framing":42}"#.utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilForWrongTypeFramingObject() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"journal_age_days":1,"home_state":"warming","welcome_framing":{"a":1}}"#.utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilOn4xx() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"not found"}"#.utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilOnMalformedJSON() async {
        HomePulseURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("not json".utf8)
            )
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }

    @MainActor
    func testFetchReturnsNilOnTimeout() async {
        HomePulseURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let framing = await HomePulsePoller().fetch(localPort: 7071)

        XCTAssertNil(framing)
    }
}

private final class HomePulseURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.path == "/app/home/api/pulse"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("HomePulseURLProtocol handler not set")
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
