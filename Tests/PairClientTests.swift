// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Crypto
import Network
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
        var requestURLs: [String] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(responseData: Data = Data(), statusCode: Int = 200, error: URLError? = nil) {
        state.withLock {
            $0.responseData = responseData
            $0.statusCode = statusCode
            $0.error = error
            $0.requestURLs = []
        }
    }

    static func requestURLs() -> [String] {
        state.withLock { $0.requestURLs }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let current = Self.state.withLock { state in
            state.requestURLs.append(request.url?.absoluteString ?? "")
            return state
        }
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
    func testRelayKeyDerivationMatchesPairWindowVector() throws {
        let s = Self.data(hex: "0123456789abcdef")

        XCTAssertEqual(CertChain.hex(PairWindowCrypto.deriveRelayKey(s: s)), "e34481a4cde647ba9c9fb29a59e18271")
    }

    func testJIDDerivationMatchesReferenceVector() throws {
        let spki = Self.data(hex: Self.referenceSPKIHex)

        let jid = try PairWindowCrypto.jid(fromSPKIDER: spki)

        XCTAssertEqual(jid.uuidString.lowercased(), "f30ed159-ef46-8e9c-913f-e49f0fe7d201")
    }

    func testCertExtractedJIDMatchesFixtureVector() throws {
        let ca = try XCTUnwrap(CertChain.certificates(fromPEM: CertlessTrustFixtures.caPEM).first)
        let spki = try XCTUnwrap(CertChain.subjectPublicKeyInfoDER(certificate: ca))

        let jid = try PairWindowCrypto.jid(fromSPKIDER: Data(spki))

        XCTAssertEqual(jid.uuidString.lowercased(), Self.fixtureCAJID)
    }

    func testRelayPairDialRequestUsesPairKeyWithoutInstanceOrBearer() throws {
        let request = try RelayWSTransport.makeRequest(
            endpoint: URL(string: "https://link.solstone.app")!,
            path: "session/pair-dial",
            authorization: .pairKey(rkHex: "e34481a4cde647ba9c9fb29a59e18271")
        )

        XCTAssertEqual(request.url?.absoluteString, "wss://link.solstone.app/session/pair-dial")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Pair-Key"), "e34481a4cde647ba9c9fb29a59e18271")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPairWindowInnerPathUsesLowercaseSHexToken() {
        XCTAssertEqual(
            PairClient.pairWindowInnerPath(s: Self.data(hex: "0123456789abcdef")),
            "/app/network/pair?token=0123456789abcdef"
        )
    }

    func testTunnelPairHTTPRequestUsesRelativeMuxPath() throws {
        let body = Data(#"{"csr":"pem","device_label":"phone"}"#.utf8)
        let request = PairClient.buildHTTPRequest(
            method: "POST",
            path: "/app/network/pair?token=012345",
            body: body
        )
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("POST /app/network/pair?token=012345 HTTP/1.1\r\n"))
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

    func testLANResponseDecodesLocalEndpointIPWireKey() throws {
        let json = """
        {"instance_id":"i","home_label":"h","client_cert":"c","ca_chain":[],"home_attestation":"a","local_endpoints":[{"ip":"192.168.1.10","port":7657,"scope":"lan"}]}
        """

        let response = try PairClient.decodeLANResponse(data: Data(json.utf8))
        XCTAssertEqual(response.localEndpoints.count, 1)
        let endpoint = try XCTUnwrap(response.localEndpoints.first)

        XCTAssertEqual(endpoint.host, "192.168.1.10")
        XCTAssertEqual(endpoint.port, 7657)
        XCTAssertEqual(endpoint.scope, "lan")
    }

    func testLANResponseDefaultsMissingLocalEndpointsToEmpty() throws {
        let json = """
        {"instance_id":"i","home_label":"h","client_cert":"c","ca_chain":[],"home_attestation":"a"}
        """

        let response = try PairClient.decodeLANResponse(data: Data(json.utf8))

        XCTAssertEqual(response.localEndpoints, [])
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

    func testDirectPairRelayFailureCompletesPairingAsUnavailable() async throws {
        let client = PairClient(
            session: Self.relaySession(error: URLError(.cannotConnectToHost)),
            lanTransport: Self.successfulLANTransport()
        )
        let pairURL = try PairURL.parse(Self.canonicalURL())
        XCTAssertEqual(pairURL.kind, .direct)

        let pairing = try await client.pair(
            pairURL: pairURL,
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

    func testDirectPairRelaySuccessStoresTokenAndAddsRelayCandidate() async throws {
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData(deviceToken: "relay-token")),
            lanTransport: Self.successfulLANTransport()
        )
        let pairURL = try PairURL.parse(Self.canonicalURL())
        XCTAssertEqual(pairURL.kind, .direct)

        let pairing = try await client.pair(
            pairURL: pairURL,
            deviceLabel: "test phone",
            relayEndpoint: Self.relayEndpoint
        )

        XCTAssertEqual(pairing.relayEnrollment, .enrolled(deviceToken: "relay-token", expiresAt: "2036-01-01T00:00:00Z"))
        let candidates = try TransportEndpoint.candidates(for: pairing)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates.contains(.lan(host: "192.0.2.42", port: 7070, scope: "")))
        XCTAssertTrue(candidates.contains(.lan(host: "10.0.0.2", port: 9443, scope: "wifi")))
        XCTAssertTrue(candidates.contains(.relay(endpoint: Self.relayEndpoint, instanceID: "instance-123", deviceToken: "relay-token")))
    }

    func testTransportCandidatesSkipInvalidRelayURLAndKeepLAN() async throws {
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData(deviceToken: "relay-token")),
            lanTransport: Self.successfulLANTransport()
        )
        let pairing = try await client.pair(
            pairURL: try PairURL.parse(Self.canonicalURL()),
            deviceLabel: "test phone",
            relayEndpoint: Self.relayEndpoint
        )
        let badRelayEndpoint = "http://bad host:7070"
        XCTAssertNil(URL(string: badRelayEndpoint))
        let badRelayPairing = StoredPairing(
            instanceID: pairing.instanceID,
            homeLabel: pairing.homeLabel,
            relayEndpoint: badRelayEndpoint,
            fingerprint: pairing.fingerprint,
            clientCertPEM: pairing.clientCertPEM,
            clientKeyPEM: pairing.clientKeyPEM,
            caChainPEM: pairing.caChainPEM,
            relayEnrollment: pairing.relayEnrollment,
            localEndpoints: pairing.localEndpoints,
            pairedAt: pairing.pairedAt
        )

        let candidates = try TransportEndpoint.candidates(for: badRelayPairing)

        XCTAssertEqual(candidates, [
            .lan(host: "192.0.2.42", port: 7070, scope: ""),
            .lan(host: "10.0.0.2", port: 9443, scope: "wifi"),
        ])
    }

    func testRelayFinalizeEnrollmentFailureCompletesPairingAsUnavailable() async throws {
        let client = PairClient(
            session: Self.relaySession(error: URLError(.cannotConnectToHost)),
            lanTransport: Self.successfulLANTransport()
        )
        let lanResponse = try PairClient.decodeLANResponse(data: Self.lanSuccessData(instanceID: Self.fixtureCAJID))

        let pairing = try await client.finalizeRelayPairing(
            lanResponse: lanResponse,
            caPin: try Self.caPinForFixture(),
            generated: PairingMaterial(csrPEM: "unused", privateKeyPEM: "private-key"),
            relayEndpoint: Self.relayEndpoint
        )

        XCTAssertEqual(pairing.relayEnrollment, .unavailable)
        XCTAssertEqual(pairing.relayEndpoint, Self.relayEndpoint.absoluteString)
        XCTAssertEqual(try TransportEndpoint.candidates(for: pairing), [
            .lan(host: "10.0.0.2", port: 9443, scope: "wifi")
        ])
    }

    func testRelayFinalizeInstanceMismatchThrowsBeforeEnrollment() async throws {
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: Self.successfulLANTransport()
        )
        let lanResponse = try PairClient.decodeLANResponse(data: Self.lanSuccessData(instanceID: "different-instance"))

        do {
            _ = try await client.finalizeRelayPairing(
                lanResponse: lanResponse,
                caPin: try Self.caPinForFixture(),
                generated: PairingMaterial(csrPEM: "unused", privateKeyPEM: "private-key"),
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected relay instance mismatch")
        } catch let error as PairError {
            XCTAssertEqual(error, .relayInstanceMismatch)
        }
        XCTAssertFalse(RelayURLProtocol.requestURLs().contains { $0.contains("/enroll/device") })
    }

    func testRelayVerifyInstanceIDMatchesFixtureCA() throws {
        let lanResponse = try PairClient.decodeLANResponse(data: Self.lanSuccessData(instanceID: Self.fixtureCAJID))

        XCTAssertNoThrow(try PairClient.verifyRelayInstanceID(lanResponse: lanResponse, caPin: try Self.caPinForFixture()))
    }

    func testRelayVerifyInstanceIDRejectsMismatch() throws {
        let lanResponse = try PairClient.decodeLANResponse(data: Self.lanSuccessData(instanceID: "different-instance"))

        XCTAssertThrowsError(try PairClient.verifyRelayInstanceID(lanResponse: lanResponse, caPin: try Self.caPinForFixture())) {
            XCTAssertEqual($0 as? PairError, .relayInstanceMismatch)
        }
    }

    func testRelayPairDialUnauthorizedMapsToPairingWindowClosed() async throws {
        let server = try await PairDialHTTPServer.start(status: 401)
        defer { server.stop() }
        let client = PairClient(
            session: Self.relaySession(responseData: Self.relaySuccessData()),
            lanTransport: Self.successfulLANTransport()
        )

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.relayURL(origin: "http://127.0.0.1:\(server.port)")),
                deviceLabel: "test phone",
                relayEndpoint: Self.relayEndpoint
            )
            XCTFail("expected pairing window closed")
        } catch let error as PairError {
            XCTAssertEqual(error, .pairingWindowClosed)
        }
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
                XCTAssertFalse(literal.contains("https://") && literal.contains("/app/network/pair"))
            }
        }
        let postDirectPair = try Self.slice(text, from: "private func postDirectPair", to: "private func postRelay")
        XCTAssertFalse(postDirectPair.contains("URLSession"))
        XCTAssertFalse(postDirectPair.contains("data(for:"))
    }

    func testRelayPairKeepsTunnelPostRequiredBeforeFinalize() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let file = root.appendingPathComponent("Sources/SPLTunnel/Pair/PairClient.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let pairViaRelay = try Self.slice(text, from: "private func pairViaRelay", to: "func finalizeRelayPairing")

        XCTAssertTrue(pairViaRelay.contains("lanResponse = try await Self.postPairThroughTunnel"))
        XCTAssertFalse(pairViaRelay.contains("try? await Self.postPairThroughTunnel"))
        let tunnelPost = try XCTUnwrap(pairViaRelay.range(of: "try await Self.postPairThroughTunnel"))
        let finalize = try XCTUnwrap(pairViaRelay.range(of: "return try await finalizeRelayPairing"))
        XCTAssertLessThan(tunnelPost.lowerBound, finalize.lowerBound)
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
        instanceID: String = "instance-123",
        localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")]
    ) throws -> Data {
        try JSONEncoder().encode(LANResponsePayload(
            instanceID: instanceID,
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

    private static func relayURL(origin: String) -> URL {
        let originBytes = Array(origin.utf8)
        let bytes: [UInt8] = [
            0x06,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01,
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            UInt8(originBytes.count),
        ] + originBytes
        return URL(string: "https://go.solstone.app/p#\(encode(bytes))")!
    }

    private static func caPinForFixture() throws -> PairingCAPin {
        let ca = try XCTUnwrap(CertChain.certificates(fromPEM: CertlessTrustFixtures.caPEM).first)
        let spki = try XCTUnwrap(CertChain.subjectPublicKeyInfoDER(certificate: ca))
        return PairingCAPin(kind: .spkiSHA256, prefixBytes: Array(SHA256.hash(data: Data(spki))))
    }

    private static func data(hex: String) -> Data {
        precondition(hex.count.isMultiple(of: 2))
        var bytes: [UInt8] = []
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            bytes.append(UInt8(hex[cursor..<next], radix: 16)!)
            cursor = next
        }
        return Data(bytes)
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output = ""

        for byte in bytes {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((accumulator >> UInt64(bitCount)) & 0x1f)
                output.append(alphabet[index])
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }

        if bitCount > 0 {
            let index = Int((accumulator << UInt64(5 - bitCount)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }

    private static let referenceSPKIHex = "3059301306072a8648ce3d020106082a8648ce3d03010703420004471c3e758c4904285bba7e53118ed0f524adeb0757d25bd2f8e7b0d76dfa714cdd520f7aca8a8b917acc37f51de8f0c9bbe3ad858382e702dc25a12d09f7a858"
    private static let fixtureCAJID = "4b03f493-0aae-88bc-936a-d13a350109f4"
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

private final class PairDialHTTPServer: @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(status: Int) async throws -> PairDialHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = PairDialServerReadyWaiter()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .utility))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let body = "HTTP/1.1 \(status) Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.complete(.success(()))
            case .failed(let error):
                ready.complete(.failure(error))
            case .cancelled:
                ready.complete(.failure(CancellationError()))
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.start(queue: .global(qos: .utility))
        try await ready.wait()
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        return PairDialHTTPServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }
}

private final class PairDialServerReadyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result: Result<Void, Error>? = lock.withLock {
                if let existing = self.result {
                    return existing
                }
                self.continuation = continuation
                return nil as Result<Void, Error>?
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ result: Result<Void, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<Void, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
