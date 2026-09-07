// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

private final class HandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    func set(_ h: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        defer { lock.unlock() }
        handler = h
    }

    func get() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

final class AuthenticatedHomeClientTests: XCTestCase {
    final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        private static let box = HandlerBox()

        static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
            get { box.get() }
            set { box.set(newValue) }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = MockURLProtocol.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeTestClient() -> AuthenticatedHomeClient {
        AuthenticatedHomeClient(sessionFactory: { _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            config.connectionProxyDictionary = [:]
            return URLSession(
                configuration: config,
                delegate: JournalVersionRedirectDelegate(),
                delegateQueue: nil
            )
        })
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private static func extractBody(from request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    func testProxyIsolationInDefaultSessionFactory() {
        let session = AuthenticatedHomeClient.defaultSessionFactory(.seconds(5))
        defer { session.invalidateAndCancel() }
        XCTAssertEqual(session.configuration.connectionProxyDictionary?.count, 0)
    }

    func testRedirectRefusedWithSingleRequest() async throws {
        final class CountBox: @unchecked Sendable {
            var count = 0
        }
        let box = CountBox()
        MockURLProtocol.requestHandler = { request in
            box.count += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://evil.example/steal"]
            )!
            return (response, Data())
        }

        let client = makeTestClient()
        let result = await client.fetchClientsSelf(localPort: 7071)
        XCTAssertEqual(box.count, 1)
        XCTAssertEqual(result, .malformedOrFailed)
    }

    func testPutClientsSelfPayloadEncodingWithNulls() async throws {
        final class BodyBox: @unchecked Sendable {
            var body: Data?
        }
        let box = BodyBox()
        MockURLProtocol.requestHandler = { request in
            box.body = Self.extractBody(from: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }

        let client = makeTestClient()
        let payload = ClientsSelfPutPayload(
            expectedRevision: 5,
            reported: ClientsSelfReported(
                name: nil,
                platform: "ios",
                deviceType: nil,
                appID: "app.solstone.swift",
                appVersion: nil
            )
        )
        let result = await client.putClientsSelf(localPort: 7071, payload: payload)
        XCTAssertEqual(result, .success)

        let body = try XCTUnwrap(box.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["protocol_version"] as? Int, 1)
        XCTAssertEqual(json["expected_revision"] as? Int, 5)

        let reported = try XCTUnwrap(json["reported"] as? [String: Any?])
        XCTAssertTrue(reported.keys.contains("name"))
        XCTAssertNil(reported["name"] as? String)
        XCTAssertEqual(reported["platform"] as? String, "ios")
        XCTAssertTrue(reported.keys.contains("device_type"))
        XCTAssertNil(reported["device_type"] as? String)
        XCTAssertEqual(reported["app_id"] as? String, "app.solstone.swift")
        XCTAssertTrue(reported.keys.contains("app_version"))
        XCTAssertNil(reported["app_version"] as? String)
    }

    func testFetchClientsSelfSuccess() async throws {
        let json = """
        {
            "protocol_version": 1,
            "revision": 3,
            "reported": {
                "name": "Old Phone",
                "platform": "ios",
                "device_type": "phone",
                "app_id": "app.solstone.swift",
                "app_version": "1.0.0"
            },
            "journal": {
                "name": "Alice's Journal",
                "version": "2.4.0"
            }
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/app/network/api/clients/self",
                  request.value(forHTTPHeaderField: "Cache-Control") == "no-cache" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, json)
        }

        let client = makeTestClient()
        let result = await client.fetchClientsSelf(localPort: 7071)

        if case .success(let resource) = result {
            XCTAssertEqual(resource.protocolVersion, 1)
            XCTAssertEqual(resource.revision, 3)
            XCTAssertEqual(resource.reported?.name, "Old Phone")
            XCTAssertEqual(resource.journal?.name, "Alice's Journal")
            XCTAssertEqual(resource.journal?.version, "2.4.0")
        } else {
            XCTFail("Expected success, got \(result)")
        }
    }

    func testFetchClientsSelfMalformed200() async {
        let badJSON = """
        {
            "protocol_version": 2,
            "revision": 3
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, badJSON)
        }

        let client = makeTestClient()
        let result = await client.fetchClientsSelf(localPort: 7071)
        XCTAssertEqual(result, .malformedOrFailed)
    }

    func testFetchClientsSelfNotFound() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeTestClient()
        let result = await client.fetchClientsSelf(localPort: 7071)
        XCTAssertEqual(result, .notFound)
    }

    func testPutClientsSelfConflict() async throws {
        MockURLProtocol.requestHandler = { request in
            guard request.httpMethod == "PUT" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeTestClient()
        let payload = ClientsSelfPutPayload(
            expectedRevision: 2,
            reported: ClientsSelfReported(
                name: "New Phone",
                platform: "ios",
                deviceType: "phone",
                appID: "app.solstone.swift",
                appVersion: "1.0.1"
            )
        )
        let result = await client.putClientsSelf(localPort: 7071, payload: payload)
        XCTAssertEqual(result, .conflict)
    }

    func testFetchRelayAccess503AndReadyAndNotConfiguredAndExtraKeys() async throws {
        let client = makeTestClient()

        // 503 -> unavailable
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let unavailableResult = await client.fetchRelayAccess(localPort: 7071)
        XCTAssertEqual(unavailableResult, .unavailable(503))

        // Ready
        let readyJSON = """
        {
            "protocol_version": 2,
            "status": "ready",
            "instance_id": "inst-1",
            "relay_origin": "https://relay.example.com",
            "device_token": "token.jwt.here",
            "expires_at": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, readyJSON)
        }

        let readyResult = await client.fetchRelayAccess(localPort: 7071)
        if case .ready(let payload) = readyResult {
            XCTAssertEqual(payload.protocolVersion, 2)
            XCTAssertEqual(payload.status, "ready")
            XCTAssertEqual(payload.relayOrigin, "https://relay.example.com")
        } else {
            XCTFail("Expected ready, got \(readyResult)")
        }

        // not_configured exact keys
        let notConfiguredJSON = """
        {
            "protocol_version": 2,
            "status": "not_configured"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, notConfiguredJSON)
        }

        let notConfiguredResult = await client.fetchRelayAccess(localPort: 7071)
        XCTAssertEqual(notConfiguredResult, .notConfigured)

        // extra keys on not_configured -> malformed
        let extraKeysJSON = """
        {
            "protocol_version": 2,
            "status": "not_configured",
            "unexpected": "extra"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, extraKeysJSON)
        }

        let extraKeysResult = await client.fetchRelayAccess(localPort: 7071)
        XCTAssertEqual(extraKeysResult, .malformedOrFailed)
    }

    func testResponseCapRejectsOver64KiB() async {
        let bigData = Data(repeating: 0x41, count: 65_537)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, bigData)
        }

        let client = makeTestClient()
        let result = await client.fetchClientsSelf(localPort: 7071)
        XCTAssertEqual(result, .malformedOrFailed)
    }
}
