// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

private final class PairingAuthorizationURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.handlerBox.withLock { $0 }

        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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

private final class PairingHeaderStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func store(path: String, authorization: String?) {
        self.lock.lock()
        self.values[path] = authorization
        self.lock.unlock()
    }

    func authorization(for path: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values[path]
    }
}

nonisolated final class PairingClientAuthorizationTests: XCTestCase {
    override func tearDown() {
        PairingAuthorizationURLProtocol.handlerBox.withLock { $0 = nil }
        super.tearDown()
    }

    @MainActor
    func testAuthenticatedEndpointsIncludeBearerHeader() async throws {
        let headerStore = PairingHeaderStore()
        PairingAuthorizationURLProtocol.handlerBox.withLock { handler in
            handler = { request in
                let path = request.url?.path ?? ""
                headerStore.store(path: path, authorization: request.value(forHTTPHeaderField: "Authorization"))

                let statusCode: Int
                let body: Data
                switch path {
                case "/api/settings/briefing-time":
                    statusCode = 200
                    body = Data("{}".utf8)
                case "/api/home/progress-today":
                    statusCode = 200
                    body = Data(#"{"segments_observed":1,"meetings_detected":2,"entities_identified":3,"percent":4,"briefing_ready":false}"#.utf8)
                case "/api/pairing/devices/device-123":
                    statusCode = 204
                    body = Data()
                default:
                    statusCode = 404
                    body = Data()
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
                return (response, body)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingAuthorizationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = LivePairingClient(
            session: session,
            retryDelays: [],
            journalRootProvider: { "http://127.0.0.1:8676" }
        )

        try await client.setBriefingTime(hour: 7, minute: 0, tzIdentifier: "America/Denver", sessionKey: "pair-session")
        _ = try await client.progressToday(sessionKey: "pair-session")
        try await client.unpair(deviceID: "device-123", sessionKey: "pair-session")

        XCTAssertEqual(headerStore.authorization(for: "/api/settings/briefing-time"), "Bearer pair-session")
        XCTAssertEqual(headerStore.authorization(for: "/api/home/progress-today"), "Bearer pair-session")
        XCTAssertEqual(headerStore.authorization(for: "/api/pairing/devices/device-123"), "Bearer pair-session")
    }
}
