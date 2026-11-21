// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
import SPLTunnel
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

    func testEmptyAboutVersionKeepsFixedWireValue() async throws {
        for version in ["", "v"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "protocol_version": 1, "version": version, "os": "linux",
                "os_version": "6.0", "arch": "x86_64", "about": "journal unknown",
            ])
            MockURLProtocol.requestHandler = { request in
                XCTAssertEqual(request.url?.path, "/api/system/about")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let result = await self.makeTestClient().fetchAbout(localPort: 7071)
            guard case .success(let facts) = result else {
                XCTFail("empty About version lost its fixed wire value")
                continue
            }
            XCTAssertEqual(facts.version, "")
            XCTAssertEqual(facts.os, "linux")
        }
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

    private func makeValidDeviceToken(instanceID: String = "inst-1", now: Date = Date(), expOffset: TimeInterval = 3600) -> (token: String, expiresAt: String) {
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + Int(expOffset)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAt = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))
        let claims: [String: Any] = [
            "iss": "independent-issuer",
            "sub": "instance:\(instanceID)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instanceID,
            "iat": iat,
            "exp": exp,
            "jti": "secret-jti"
        ]
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).sig"
        return (token, expiresAt)
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
        let responseResourceJSON = """
        {
            "protocol_version": 1,
            "revision": 6,
            "reported": {
                "name": null,
                "platform": "ios",
                "device_type": null,
                "app_id": "app.solstone.swift",
                "app_version": null
            },
            "owner_label": null,
            "display_label": "Alice's iPhone",
            "updated_at": "2026-03-30T12:00:00Z",
            "journal": {
                "name": "Alice's Journal",
                "version": "2.4.0"
            }
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            box.body = Self.extractBody(from: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseResourceJSON)
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
        if case .success(let res) = result {
            XCTAssertEqual(res.revision, 6)
            XCTAssertEqual(res.displayLabel, "Alice's iPhone")
        } else {
            XCTFail("Expected success, got \(result)")
        }

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
            "owner_label": "Alice",
            "display_label": "Alice's Phone",
            "updated_at": "2026-03-30T12:00:00Z",
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
            XCTAssertEqual(resource.journal.name, "Alice's Journal")
            XCTAssertEqual(resource.journal.version, "2.4.0")
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
        let unavailableResult = await client.fetchRelayAccess(localPort: 7071, expectedInstanceID: "inst-1")
        XCTAssertEqual(unavailableResult, .unavailable(503))

        // Ready
        let (token, expiresAt) = makeValidDeviceToken(instanceID: "inst-1")
        let readyJSON = """
        {
            "protocol_version": 2,
            "status": "ready",
            "instance_id": "inst-1",
            "relay_origin": "https://relay.example.com",
            "device_token": "\(token)",
            "expires_at": "\(expiresAt)"
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

        let readyResult = await client.fetchRelayAccess(localPort: 7071, expectedInstanceID: "inst-1")
        if case .ready(let ready) = readyResult {
            XCTAssertEqual(ready.instanceID, "inst-1")
            XCTAssertEqual(ready.relayOrigin.absoluteString, "https://relay.example.com")
            XCTAssertEqual(ready.deviceToken, token)
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

        let notConfiguredResult = await client.fetchRelayAccess(localPort: 7071, expectedInstanceID: "inst-1")
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

        let extraKeysResult = await client.fetchRelayAccess(localPort: 7071, expectedInstanceID: "inst-1")
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

        let statusResult = await client.fetchStatus(localPort: 7071)
        XCTAssertNil(statusResult)

        let putResult = await client.putClientsSelf(
            localPort: 7071,
            payload: ClientsSelfPutPayload(
                expectedRevision: 1,
                reported: ClientsSelfReported(
                    name: nil,
                    platform: "ios",
                    deviceType: nil,
                    appID: "app.solstone.swift",
                    appVersion: nil
                )
            )
        )
        XCTAssertEqual(putResult, ClientsSelfPutResult.failed)

        let relayResult = await client.fetchRelayAccess(localPort: 7071, expectedInstanceID: "inst-1")
        XCTAssertEqual(relayResult, .malformedOrFailed)
    }

    func testRelayAccessValidationBoundaryTable() async throws {
        let client = makeTestClient()
        let testNow = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        func makeCustomToken(
            instanceID: String = "inst-1",
            iat: Int,
            exp: Int,
            jti: String = "secret-jti",
            customSegments: String? = nil
        ) -> String {
            if let customSegments { return customSegments }
            let claims: [String: Any] = [
                "iss": "independent-issuer",
                "sub": "instance:\(instanceID)",
                "aud": "spl-relay",
                "scope": "session.dial",
                "ver": 2,
                "instance_id": instanceID,
                "iat": iat,
                "exp": exp,
                "jti": jti
            ]
            let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "e30.\(payload).sig"
        }

        func testCase(
            origin: String,
            token: String,
            expiresAt: String,
            expectedSuccess: Bool
        ) async {
            let json = """
            {
                "protocol_version": 2,
                "status": "ready",
                "instance_id": "inst-1",
                "relay_origin": "\(origin)",
                "device_token": "\(token)",
                "expires_at": "\(expiresAt)"
            }
            """.data(using: .utf8)!

            MockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, json)
            }

            let result = await client.fetchRelayAccess(localPort: 7071, expectedInstanceID: "inst-1", now: testNow)
            if expectedSuccess {
                guard case .ready = result else {
                    XCTFail("Expected success for origin: \(origin), token: \(token), expiresAt: \(expiresAt), got: \(result)")
                    return
                }
            } else {
                XCTAssertEqual(result, .malformedOrFailed, "Expected malformedOrFailed for origin: \(origin), token: \(token), expiresAt: \(expiresAt)")
            }
        }

        let validIat = Int(testNow.timeIntervalSince1970)
        let validExp = validIat + 3600
        let validExpiresAt = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(validExp)))
        let validToken = makeCustomToken(iat: validIat, exp: validExp)

        // 1. iat exactly now + 60 -> pass
        let iat60Token = makeCustomToken(iat: validIat + 60, exp: validExp)
        await testCase(origin: "https://relay.example.com", token: iat60Token, expiresAt: validExpiresAt, expectedSuccess: true)

        // 2. iat now + 61 -> fail
        let iat61Token = makeCustomToken(iat: validIat + 61, exp: validExp)
        await testCase(origin: "https://relay.example.com", token: iat61Token, expiresAt: validExpiresAt, expectedSuccess: false)

        // 3. invalid origins: wss, userinfo, path, query, fragment, http
        await testCase(origin: "wss://relay.example.com", token: validToken, expiresAt: validExpiresAt, expectedSuccess: false)
        await testCase(origin: "https://user:pass@relay.example.com", token: validToken, expiresAt: validExpiresAt, expectedSuccess: false)
        await testCase(origin: "https://relay.example.com/some/path", token: validToken, expiresAt: validExpiresAt, expectedSuccess: false)
        await testCase(origin: "https://relay.example.com?query=val", token: validToken, expiresAt: validExpiresAt, expectedSuccess: false)
        await testCase(origin: "https://relay.example.com#fragment", token: validToken, expiresAt: validExpiresAt, expectedSuccess: false)
        await testCase(origin: "http://relay.example.com", token: validToken, expiresAt: validExpiresAt, expectedSuccess: false)

        // 4. JWT segments: empty or extra segments
        let twoSegmentToken = "e30.payload"
        await testCase(origin: "https://relay.example.com", token: twoSegmentToken, expiresAt: validExpiresAt, expectedSuccess: false)
        let fourSegmentToken = "e30.payload.sig.extra"
        await testCase(origin: "https://relay.example.com", token: fourSegmentToken, expiresAt: validExpiresAt, expectedSuccess: false)
        let emptyMiddleSegment = "e30..sig"
        await testCase(origin: "https://relay.example.com", token: emptyMiddleSegment, expiresAt: validExpiresAt, expectedSuccess: false)

        // 5. empty jti -> fail
        let emptyJtiToken = makeCustomToken(iat: validIat, exp: validExp, jti: "")
        await testCase(origin: "https://relay.example.com", token: emptyJtiToken, expiresAt: validExpiresAt, expectedSuccess: false)

        // 6. expired during fetch (exp <= now)
        let expiredExp = validIat - 10
        let expiredExpiresAt = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(expiredExp)))
        let expiredToken = makeCustomToken(iat: validIat - 100, exp: expiredExp)
        await testCase(origin: "https://relay.example.com", token: expiredToken, expiresAt: expiredExpiresAt, expectedSuccess: false)

        // 7. fractional RFC3339 mismatch
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalExpiresAt = fractionalFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(validExp) + 0.5))
        await testCase(origin: "https://relay.example.com", token: validToken, expiresAt: fractionalExpiresAt, expectedSuccess: false)
    }
    func testClientsSelfRevisionPreservesFullUInt64WireRange() throws {
        let data = Data("""
        {"protocol_version":1,"revision":18446744073709551615,"reported":null,"owner_label":null,"display_label":"Phone","updated_at":null,"journal":{"name":null,"version":"1.0"}}
        """.utf8)
        let resource = try JSONDecoder().decode(ClientsSelfResource.self, from: data)
        XCTAssertEqual(resource.revision, UInt64.max)
        let encoded = try JSONEncoder().encode(ClientsSelfPutPayload(expectedRevision: resource.revision, reported: ClientsSelfReported()))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("18446744073709551615"))
        let negative = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "18446744073709551615", with: "-1").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ClientsSelfResource.self, from: negative))
    }

}


extension AuthenticatedHomeClientTests {
    @MainActor
    func testSharedSourceWireAndPairingLifetime() async throws {
        let pairing = StoredPairing(instanceID: "journal", homeLabel: "Desk",
            relayEndpoint: "wss://example.test", fingerprint: "device",
            clientCertPEM: CertlessTrustFixtures.leafPEM, clientKeyPEM: "test", caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable, localEndpoints: [], pairedAt: Date())
        let store = PairingCredentialStore(confirmationStore: .memory(), migrationStore: .memory(),
            loadPairing: { pairing }, savePairing: { _ in }, deletePairing: {})
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = makeTestClient()
        let service = SharedSources(credentials: store, defaults: defaults, client: client)
        service.admitted = { true }
        let identity = try XCTUnwrap(service.currentIdentity)
        let link = SharedSources.Connection(identity: identity, port: 7071, epoch: 1)
        let item = try XCTUnwrap(SourceDeclaration(makeAudioSource(state: .paused, attention: nil, isJournalPaired: true)))
        let written = expectation(description: "local paused source declared")
        @Sendable nonisolated func reply(_ request: URLRequest, _ code: Int, _ body: String) -> (HTTPURLResponse, Data) {
            (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let doc = """
        {"sources_rev":"v1","self_cid":"this","devices":[
        {"cid":"this","display_label":"same name","sources":[{"source":"calendar","origin":"declared","state":"on"}]},
        {"cid":"older","display_label":"same name","device_last_seen_at":"2026-11-20T12:05:00Z",
         "sources":[{"source":"calendar","origin":"observed","last_synced_at":"2026-11-01T12:00:00Z"}]},
        {"cid":"recent","display_label":"work laptop","device_last_seen_at":"2026-11-20T12:00:00.123Z",
         "sources":[{"source":"calendar","origin":"declared","state":"paused","declared_at":"2026-11-19T00:00:00Z"}]}]}
        """
        let initialResponse: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            switch request.url?.path {
            case "/api/system/status": return reply(request, 200, #"{"capabilities":["shared_sources"],"sources_rev":"v1"}"#)
            case "/app/network/api/sources": return reply(request, 200, doc)
            case "/app/network/api/clients/self/sources":
                XCTAssertEqual(request.httpMethod, "PUT")
                let body = try XCTUnwrap(Self.extractBody(from: request))
                XCTAssertEqual(try JSONDecoder().decode([SourceDeclaration].self, from: body), [item])
                return reply(request, 204, "")
            default: throw URLError(.badURL)
            }
        }
        MockURLProtocol.requestHandler = { request in
            let response = try initialResponse(request)
            if request.httpMethod == "PUT" { written.fulfill() }
            return response
        }
        service.update(identity: identity, connection: link, declarations: [item])
        await service.task?.value
        await fulfillment(of: [written], timeout: 2)
        let firstWrite = expectation(description: "changed declaration is on the wire")
        let latestWrite = expectation(description: "empty declaration follows the first write")
        let releaseFirst = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            let bytes = try XCTUnwrap(Self.extractBody(from: request))
            let sent = try JSONDecoder().decode([SourceDeclaration].self, from: bytes)
            if sent.isEmpty {
                latestWrite.fulfill()
            } else {
                XCTAssertEqual(sent.first?.state, "on")
                firstWrite.fulfill()
                XCTAssertEqual(releaseFirst.wait(timeout: .now() + 5), .success)
                return reply(request, 503, "")
            }
            return reply(request, 204, "")
        }
        let active = try XCTUnwrap(SourceDeclaration(makeAudioSource(state: .active, attention: nil, isJournalPaired: true)))
        service.update(identity: identity, connection: link, declarations: [active])
        await fulfillment(of: [firstWrite], timeout: 3)
        service.update(identity: identity, connection: link, declarations: [])
        releaseFirst.signal()
        await service.task?.value
        await fulfillment(of: [latestWrite], timeout: 3)
        service.update(identity: identity, connection: nil, declarations: [])
        let devices = service.others("calendar")
        XCTAssertEqual(devices.map(\.cid), ["recent", "older"])
        let device = try XCTUnwrap(devices.first)
        let entry = try XCTUnwrap(device.sources.first)
        let seen = try XCTUnwrap(device.latest)
        XCTAssertEqual(SharedSourceCopy.line(device: device, entry: entry, now: seen.addingTimeInterval(240)),
                       "work laptop · paused · 4 min ago")
        XCTAssertEqual(SharedSourceCopy.line(device: device, entry: entry, spoken: true, now: seen.addingTimeInterval(480)),
                       "work laptop, paused, 8 minutes ago")
        service.admitted = { false }
        XCTAssertTrue(service.others("calendar").isEmpty)
        service.admitted = { true }

        let offline = SharedSources(credentials: store, defaults: defaults, client: client)
        offline.admitted = { true }
        offline.update(identity: identity, connection: nil, declarations: [])
        XCTAssertEqual(offline.others("calendar").map(\.cid), ["recent", "older"])

        MockURLProtocol.requestHandler = { request in reply(request, 503, "") }
        offline.update(identity: identity, connection: link, declarations: [])
        await offline.task?.value
        XCTAssertEqual(offline.others("calendar").count, 2)
        MockURLProtocol.requestHandler = { request in reply(request, 403, "") }
        offline.refresh(detail: true)
        await offline.task?.value
        XCTAssertTrue(offline.others("calendar").isEmpty)
        XCTAssertNil(defaults.data(forKey: "pairedKnownSources"))

        // A revoked pairing cannot discover or publish again, including on a later connection.
        offline.update(identity: identity, connection: link, declarations: [item])
        XCTAssertNil(offline.task)
        offline.forget()
        MockURLProtocol.requestHandler = initialResponse
        offline.update(identity: identity, connection: link, declarations: [item])
        await offline.task?.value
        XCTAssertEqual(offline.others("calendar").count, 2)

        // A new owner-initiated pairing flow also wipes an existing snapshot for identical credentials.
        let lease = try store.beginPairingFlow()
        try store.applyPairing(pairing, ifPairingFlowLease: lease)
        XCTAssertNil(defaults.data(forKey: "pairedKnownSources"))
        XCTAssertTrue(offline.others("calendar").isEmpty)
        offline.update(identity: identity, connection: link, declarations: [item])
        await offline.task?.value
        XCTAssertEqual(offline.others("calendar").count, 2)

        // Unpair invalidates a populated cache synchronously, even without a SwiftUI view.
        try store.clearPairing()
        XCTAssertNil(defaults.data(forKey: "pairedKnownSources"))
        XCTAssertTrue(offline.others("calendar").isEmpty)
        try store.applyPairing(pairing)
        let sameJournal = try XCTUnwrap(offline.currentIdentity)
        offline.update(identity: sameJournal, connection: nil, declarations: [])
        XCTAssertTrue(offline.others("calendar").isEmpty)

        let nextLink = SharedSources.Connection(identity: sameJournal, port: 7071, epoch: 2)
        MockURLProtocol.requestHandler = initialResponse
        offline.update(identity: sameJournal, connection: nextLink, declarations: [item])
        await offline.task?.value
        XCTAssertEqual(offline.others("calendar").count, 2)
        let rejected = expectation(description: "invalid declaration is sent only once")
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "PUT" {
                rejected.fulfill()
                return reply(request, 400, "")
            }
            return try initialResponse(request)
        }
        offline.update(identity: sameJournal, connection: nextLink, declarations: [])
        await offline.task?.value
        offline.refresh(detail: true)
        await offline.task?.value
        await fulfillment(of: [rejected], timeout: 3)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/system/status")
            return reply(request, 200, #"{"capabilities":[]}"#)
        }
        offline.refresh(detail: true)
        await offline.task?.value
        XCTAssertTrue(offline.others("calendar").isEmpty)
        XCTAssertNil(defaults.data(forKey: "pairedKnownSources"))
    }
}
