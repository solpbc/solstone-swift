// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ObserverManifestClientTests: XCTestCase {
    override func tearDown() {
        ObserverManifestURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchTodayReturnsLoadedForNonEmptyManifest() async {
        ObserverManifestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"segments":[{"key":"meeting","observed":"today","files":[{"name":"audio.m4a"}]}]}"#.utf8)
            )
        }

        let result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")

        XCTAssertEqual(result, .loaded([
            ObserverManifestItem(id: "meeting", title: "meeting", subtitle: "today")
        ]))
    }

    func testFetchTodayReturnsLoadedEmptyForEmptyManifest() async {
        ObserverManifestURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"segments":[]}"#.utf8)
            )
        }

        let result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")

        XCTAssertEqual(result, .loadedEmpty)
    }

    func testFetchTodayReturnsFailedForNonSuccessResponse() async {
        ObserverManifestURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")

        XCTAssertEqual(result, .failed)
    }

    private var client: ObserverManifestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverManifestURLProtocol.self]
        return ObserverManifestClient(session: URLSession(configuration: configuration))
    }
}

private final class ObserverManifestURLProtocol: URLProtocol, @unchecked Sendable {
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
        XCTAssertEqual(self.request.value(forHTTPHeaderField: "Authorization"), "Bearer observer-key")
        XCTAssertEqual(self.request.url?.path, "/app/observer/ingest/manifest/\(observerManifestTestDayString())")
        guard let handler = Self.handler else {
            XCTFail("ObserverManifestURLProtocol handler not set")
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

nonisolated private func observerManifestTestDayString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: Date())
}
