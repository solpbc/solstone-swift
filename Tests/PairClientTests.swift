// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel
import XCTest
import os

private final class StubLANPairTransport: LANPairTransport, @unchecked Sendable {
    typealias Handler = @Sendable (
        _ host: String,
        _ port: Int,
        _ caFingerprintBytes: [UInt8],
        _ requestBytes: Data
    ) async throws -> (status: Int, body: Data)

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        host: String,
        port: Int,
        caFingerprintBytes: [UInt8],
        requestBytes: Data
    ) async throws -> (status: Int, body: Data) {
        try await handler(host, port, caFingerprintBytes, requestBytes)
    }
}

private final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var responseData = Data()
        var statusCode = 200
        var error: URLError?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(responseData: Data = Data(), statusCode: Int = 200, error: URLError? = nil) {
        state.withLock {
            $0.responseData = responseData
            $0.statusCode = statusCode
            $0.error = error
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let current = Self.state.withLock { $0 }
        if let error = current.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: current.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

nonisolated final class PairClientTests: XCTestCase {
    func testPairTicketRequestTargetsProductionRelayContract() throws {
        let request = try PairClient.makePairTicketRequest(
            relayEndpoint: URL(string: "https://link.solstone.app")!,
            instanceID: "12345678-1234-5678-1234-567812345678",
            totp: "123456",
            userAgent: "test-agent"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://link.solstone.app/session/pair-ticket?instance=12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "test-agent")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["instance_id"], "12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(json["totp"], "123456")
    }

    func testRelayPairDialURLConvertsProductionHTTPSOriginToWSS() throws {
        let url = try RelayWSTransport.webSocketURL(
            endpoint: URL(string: "https://link.solstone.app")!,
            path: "session/pair-dial",
            instanceID: "instance-123"
        )

        XCTAssertEqual(url.absoluteString, "wss://link.solstone.app/session/pair-dial?instance=instance-123")
    }

    func testTunnelPairHTTPRequestUsesRelativeMuxPath() throws {
        let body = Data(#"{"csr":"pem","device_label":"phone"}"#.utf8)
        let request = PairClient.buildHTTPRequest(
            method: "POST",
            path: "/app/link/pair?token=012345",
            body: body
        )
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("POST /app/link/pair?token=012345 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: spl.local\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(text.hasSuffix(String(data: body, encoding: .utf8)!))
    }

    func testRelayEnrollRequestOmitsClientCert() throws {
        let lanResponse = try PairClient.decodeLANResponse(data: Data(Self.lanResponseJSON.utf8))
        let request = try PairClient.makeRelayRequest(
            relayEndpoint: URL(string: "https://link.solstone.app")!,
            response: lanResponse,
            userAgent: "test-agent"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://link.solstone.app/enroll/device")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["instance_id"], "instance-123")
        XCTAssertEqual(json["home_attestation"], "attestation-123")
        XCTAssertNil(json["client_cert"])
    }

    private static let lanResponseJSON = """
    {
      "instance_id": "instance-123",
      "home_label": "home",
      "client_cert": "-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----\\n",
      "ca_chain": [],
      "home_attestation": "attestation-123",
      "local_endpoints": []
    }
    """

    func testLANStatusMappingCoversExpectedFailures() async throws {
        try await Self.assertPairError(.nonceExpired, lanStatus: 410)
        try await Self.assertPairError(.lanResponseInvalid(status: 400), lanStatus: 400)
        try await Self.assertPairError(.lanResponseInvalid(status: 404), lanStatus: 404)
        try await Self.assertPairError(.lanRequestFailed(underlying: nil), lanStatus: 503)
        try await Self.assertPairError(.lanResponseInvalid(status: 418), lanStatus: 418)
    }

    func testLANStatus200WithInvalidBodySurfacesInvalidResponse() async throws {
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { _, _, _, _ in
                (status: 200, body: Data("not-json".utf8))
            }
        )

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.canonicalURL()),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected PairError.lanResponseInvalid")
        } catch let error as PairError {
            XCTAssertEqual(error, .lanResponseInvalid(status: 200))
        }
    }

    func testLANTransportErrorsMapToPairErrors() async throws {
        try await Self.assertPairError(
            .lanCAFingerprintMismatch,
            lanError: InnerTLSError.caFingerprintMismatch
        )
        try await Self.assertPairError(
            .pairingWindowClosed,
            lanError: CertlessPairError.closedBeforeStatus
        )
        try await Self.assertPairError(
            .lanResponseInvalid(status: nil),
            lanError: CertlessPairError.malformedResponse
        )
    }

    func testRelayFailureCompletesPairingAsUnavailable() async throws {
        let client = PairClient(
            session: Self.relaySession(error: URLError(.cannotConnectToHost)),
            lanTransport: Self.successfulLANTransport()
        )

        let pairing = try await client.pair(
            pairURL: try PairURL.parse(Self.canonicalURL()),
            deviceLabel: "test phone",
            relayEndpoint: Self.relayEndpoint
        )

        XCTAssertEqual(pairing.relayEnrollment, .unavailable)
        let candidates = try TransportEndpoint.candidates(for: pairing)
        XCTAssertEqual(candidates, [
            .lan(host: "192.0.2.42", port: 7070, scope: ""),
            .lan(host: "10.0.0.2", port: 9443, scope: "wifi"),
        ])
    }

    func testRelaySuccessStoresTokenAndAddsRelayCandidate() async throws {
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData(deviceToken: "relay-token")),
            lanTransport: Self.successfulLANTransport()
        )

        let pairing = try await client.pair(
            pairURL: try PairURL.parse(Self.canonicalURL()),
            deviceLabel: "test phone",
            relayEndpoint: Self.relayEndpoint
        )

        XCTAssertEqual(pairing.relayEnrollment, .enrolled(deviceToken: "relay-token"))
        let candidates = try TransportEndpoint.candidates(for: pairing)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates.contains(.lan(host: "192.0.2.42", port: 7070, scope: "")))
        XCTAssertTrue(candidates.contains(.lan(host: "10.0.0.2", port: 9443, scope: "wifi")))
        XCTAssertTrue(candidates.contains(.relay(endpoint: Self.relayEndpoint, instanceID: "instance-123", deviceToken: "relay-token")))
    }

    func testDirectPairHonorsInjectedCandidateOrderAndStopsOnSuccess() async throws {
        let seenHosts = OSAllocatedUnfairLock(initialState: [String]())
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { host, _, _, _ in
                seenHosts.withLock { $0.append(host) }
                return (status: 200, body: try Self.lanSuccessData(localEndpoints: []))
            }
        )

        let pairing = try await client.pair(
            pairURL: try PairURL.parse(Self.multiAddressURL()),
            deviceLabel: "test phone",
            relayEndpoint: Self.relayEndpoint,
            orderCandidates: { Array($0.reversed()) }
        )

        XCTAssertEqual(seenHosts.withLock { $0 }, ["198.51.100.20"])
        XCTAssertEqual(pairing.localEndpoints.first, LocalEndpoint(host: "198.51.100.20", port: 7657, scope: ""))
    }

    func testDirectPairRecordsSecondCandidateWhenFirstFails() async throws {
        let seenHosts = OSAllocatedUnfairLock(initialState: [String]())
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { host, _, _, _ in
                seenHosts.withLock { $0.append(host) }
                if host == "192.0.2.10" {
                    throw URLError(.cannotConnectToHost)
                }
                return (status: 200, body: try Self.lanSuccessData(localEndpoints: [
                    LocalEndpoint(host: "198.51.100.20", port: 7657, scope: "wifi"),
                    LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")
                ]))
            }
        )

        let pairing = try await client.pair(
            pairURL: try PairURL.parse(Self.multiAddressURL()),
            deviceLabel: "test phone",
            relayEndpoint: Self.relayEndpoint
        )

        XCTAssertEqual(seenHosts.withLock { $0 }, ["192.0.2.10", "198.51.100.20"])
        XCTAssertEqual(pairing.localEndpoints.first, LocalEndpoint(host: "198.51.100.20", port: 7657, scope: "wifi"))
    }

    func testDirectPairDialsEveryCandidateBeforeConnectivityExhaustion() async throws {
        let seenHosts = OSAllocatedUnfairLock(initialState: [String]())
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { host, _, _, _ in
                seenHosts.withLock { $0.append(host) }
                throw URLError(.cannotConnectToHost)
            }
        )

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.multiAddressURL()),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected candidate exhaustion")
        } catch let error as PairError {
            XCTAssertEqual(error, .lanCandidatesExhausted(sawCAFingerprintMismatch: false))
        }
        XCTAssertEqual(seenHosts.withLock { $0 }, ["192.0.2.10", "198.51.100.20"])
    }

    func testDirectPairRetainsCAMismatchAcrossExhaustion() async throws {
        let seenHosts = OSAllocatedUnfairLock(initialState: [String]())
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { host, _, _, _ in
                seenHosts.withLock { $0.append(host) }
                if host == "192.0.2.10" {
                    throw InnerTLSError.caFingerprintMismatch
                }
                throw URLError(.cannotConnectToHost)
            }
        )

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.multiAddressURL()),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected candidate exhaustion")
        } catch let error as PairError {
            XCTAssertEqual(error, .lanCandidatesExhausted(sawCAFingerprintMismatch: true))
        }
        XCTAssertEqual(seenHosts.withLock { $0 }, ["192.0.2.10", "198.51.100.20"])
    }

    func testDirectPairNonceExpiredOnFirstCandidateStopsLoop() async throws {
        let seenHosts = OSAllocatedUnfairLock(initialState: [String]())
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { host, _, _, _ in
                seenHosts.withLock { $0.append(host) }
                return (status: 410, body: Data())
            }
        )

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.multiAddressURL()),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected nonceExpired")
        } catch let error as PairError {
            XCTAssertEqual(error, .nonceExpired)
        }
        XCTAssertEqual(seenHosts.withLock { $0 }, ["192.0.2.10"])
    }

    func testDirectPairNonceExpiredOnLaterCandidateStopsWithoutExhaustion() async throws {
        let seenHosts = OSAllocatedUnfairLock(initialState: [String]())
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { host, _, _, _ in
                seenHosts.withLock { $0.append(host) }
                if host == "192.0.2.10" {
                    throw URLError(.cannotConnectToHost)
                }
                return (status: 410, body: Data())
            }
        )

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.multiAddressURL()),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected nonceExpired")
        } catch let error as PairError {
            XCTAssertEqual(error, .nonceExpired)
        }
        XCTAssertEqual(seenHosts.withLock { $0 }, ["192.0.2.10", "198.51.100.20"])
    }

    func testDirectPairSingleCandidateRethrowsRawError() async throws {
        let seenHosts = OSAllocatedUnfairLock(initialState: [String]())
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { host, _, _, _ in
                seenHosts.withLock { $0.append(host) }
                throw URLError(.cannotConnectToHost)
            }
        )

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.alternateDirectURL()),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected raw request failure")
        } catch let error as PairError {
            XCTAssertEqual(error, .lanRequestFailed(underlying: nil))
        }
        XCTAssertEqual(seenHosts.withLock { $0 }, ["192.0.2.10"])
    }

    func testLANPairPostNoLongerUsesURLSessionOrHTTPSRequestBuilder() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let file = root.appendingPathComponent("Sources/SPLTunnel/Pair/PairClient.swift")
        let text = try String(contentsOf: file, encoding: .utf8)

        XCTAssertFalse(text.contains("makeLANRequest"))
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let literals = try StringLiteralGrepSupport.stringLiterals(in: String(line))
            for literal in literals {
                XCTAssertFalse(literal.contains("https://") && literal.contains("/app/link/pair"))
            }
        }
        let postDirectPair = try Self.slice(text, from: "private func postDirectPair", to: "private func postPairTicket")
        XCTAssertFalse(postDirectPair.contains("URLSession"))
        XCTAssertFalse(postDirectPair.contains("data(for:"))
    }

    private static func assertPairError(_ expected: PairError, lanStatus: Int) async throws {
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { _, _, _, _ in
                (status: lanStatus, body: Data())
            }
        )
        try await assertPairError(expected, client: client)
    }

    private static func assertPairError(_ expected: PairError, lanError: any Error & Sendable) async throws {
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: StubLANPairTransport { _, _, _, _ in
                throw lanError
            }
        )
        try await assertPairError(expected, client: client)
    }

    private static func assertPairError(_ expected: PairError, client: PairClient) async throws {
        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.canonicalURL()),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected \(expected)")
        } catch let error as PairError {
            XCTAssertEqual(error, expected)
        }
    }

    private static func successfulLANTransport() -> StubLANPairTransport {
        StubLANPairTransport { _, _, _, _ in
            (status: 200, body: try Self.lanSuccessData())
        }
    }

    private static func relaySession(
        responseData: Data = Data(),
        statusCode: Int = 200,
        error: URLError? = nil
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayURLProtocol.self]
        RelayURLProtocol.configure(responseData: responseData, statusCode: statusCode, error: error)
        return URLSession(configuration: configuration)
    }

    private static func lanSuccessData(
        localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")]
    ) throws -> Data {
        try JSONEncoder().encode(LANResponsePayload(
            instanceID: "instance-123",
            homeLabel: "sol",
            clientCert: CertlessTrustFixtures.leafPEM,
            caChain: [CertlessTrustFixtures.caPEM],
            homeAttestation: "attestation",
            localEndpoints: localEndpoints
        ))
    }

    private static func relaySuccessData(deviceToken: String = "device-token") -> Data {
        Data(#"{"device_token":"\#(deviceToken)","expires_at":"2036-01-01T00:00:00Z"}"#.utf8)
    }

    private static func canonicalURL() -> URL {
        URL(string: "https://go.solstone.app/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF")!
    }

    private static func alternateDirectURL() -> URL {
        URL(string: "https://go.solstone.app/p#0G0W000218EYJ001081G81860W40J2GB1G6GW3X0M6HA7955MTKTHADANEPAVBNF")!
    }

    private static func multiAddressURL() -> URL {
        URL(string: "https://go.solstone.app/p#0M0G47F9R00042P66DJ18001081G81860W40J2GB1G6GW3X0M6HA7955MTKTHADANEPAVBNF")!
    }

    private static let relayEndpoint = URL(string: "https://relay.example.com")!

    private static func slice(_ text: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start))
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex))
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }
}

private struct LANResponsePayload: Encodable {
    let instanceID: String
    let homeLabel: String
    let clientCert: String
    let caChain: [String]
    let homeAttestation: String
    let localEndpoints: [LocalEndpoint]

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case homeLabel = "home_label"
        case clientCert = "client_cert"
        case caChain = "ca_chain"
        case homeAttestation = "home_attestation"
        case localEndpoints = "local_endpoints"
    }
}
