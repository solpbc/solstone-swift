// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class JournalIdentityFetcherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(JournalIdentityURLProtocol.self)
        JournalIdentityURLProtocol.handler = nil
    }

    override func tearDown() {
        JournalIdentityURLProtocol.handler = nil
        URLProtocol.unregisterClass(JournalIdentityURLProtocol.self)
        super.tearDown()
    }

    @MainActor
    func testFetchReturnsValidMark() async throws {
        JournalIdentityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/link/api/identity")
            XCTAssertEqual(request.timeoutInterval, 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.identityData(committed: true, mark: Self.markObject())
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071)

        if case .match(let mark) = result {
            XCTAssertEqual(mark.words, ["afoot", "unfixed"])
        } else {
            XCTFail("expected .match, got \(result)")
        }
    }

    @MainActor
    func testFetchReturnsMissingOrInvalidWhenUncommitted() async {
        JournalIdentityURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.identityData(committed: false, mark: Self.markObject())
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071)

        XCTAssertEqual(result, .missingOrInvalid)
    }

    @MainActor
    func testFetchReturnsMissingOrInvalidWhenMarkNull() async {
        JournalIdentityURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.identityData(committed: true, mark: NSNull())
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071)

        XCTAssertEqual(result, .missingOrInvalid)
    }

    @MainActor
    func testFetchReturnsMissingOrInvalidForNon2xx() async {
        JournalIdentityURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"not found"}"#.utf8)
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071)

        XCTAssertEqual(result, .missingOrInvalid)
    }

    @MainActor
    func testFetchReturnsMissingOrInvalidForGarbageJSON() async {
        JournalIdentityURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("not json".utf8)
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071)

        XCTAssertEqual(result, .missingOrInvalid)
    }

    @MainActor
    func testFetchReturnsMissingOrInvalidForInvalidMark() async {
        JournalIdentityURLProtocol.handler = { request in
            var mark = Self.markObject()
            var icon2 = mark["icon2"] as! [String: Any]
            icon2["rot"] = 90
            mark["icon2"] = icon2
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.identityData(committed: true, mark: mark)
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071)

        XCTAssertEqual(result, .missingOrInvalid)
    }

    @MainActor
    func testFetchReturnsInstanceMismatchWhenInstanceDoesNotMatch() async {
        JournalIdentityURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.identityData(committed: true, mark: Self.markObject(), instanceID: "instance-other")
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071, expectedInstanceID: "instance-123")

        XCTAssertEqual(result, .instanceMismatch)
    }

    @MainActor
    func testFetchReturnsMatchForCaseDifferentInstanceID() async {
        JournalIdentityURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.identityData(committed: true, mark: Self.markObject(), instanceID: "INSTANCE-ABC-123")
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071, expectedInstanceID: "instance-abc-123")

        if case .match(let mark) = result {
            XCTAssertEqual(mark.words, ["afoot", "unfixed"])
        } else {
            XCTFail("expected .match for case-different instance ID, got \(result)")
        }
    }

    @MainActor
    func testFetchReturnsInstanceMismatchWhenInstanceIDMissingInResponse() async {
        JournalIdentityURLProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                "committed": true,
                "mark": Self.markObject(),
            ])
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let result = await JournalIdentityFetcher().fetch(localPort: 7071, expectedInstanceID: "instance-123")

        XCTAssertEqual(result, .instanceMismatch)
    }

    private static func identityData(committed: Bool, mark: Any, instanceID: String = "instance-123") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "committed": committed,
            "instance_id": instanceID,
            "mark": mark,
        ])
    }

    private static func markObject() -> [String: Any] {
        [
            "icon1": [
                "name": "bug",
                "color": ["hex": "#f59e0b"],
                "rot": 0,
                "svg": JournalMark.uiTestSample.icon1.svg,
            ],
            "icon2": [
                "name": "gem",
                "color": ["hex": "#84cc16"],
                "rot": 45,
                "svg": JournalMark.uiTestSample.icon2.svg,
            ],
            "words": ["afoot", "unfixed"],
        ]
    }
}

private final class JournalIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.path == "/app/link/api/identity"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("JournalIdentityURLProtocol handler not set")
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
