// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@testable import SPLTunnel
import os
import XCTest

// criterion 4: relay-only candidate composition and fail-closed pairing classification.
@MainActor
final class IntegrationGateRelayOnlyTests: XCTestCase {
    func testRelayOnlyPolicyRemovesBootstrapAndCachedDirectCandidatesInMemory() async throws {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plViaSpl
        let cache = EndpointCache(fileURL: Self.tempFileURL())
        let cachedPairing = Self.pairing(localEndpoints: [
            LocalEndpoint(host: "10.0.0.20", port: 7657, scope: "local"),
        ])
        await cache.bootstrap(from: cachedPairing)
        let pairing = Self.pairing(localEndpoints: [
            LocalEndpoint(host: "10.0.0.10", port: 7657, scope: "local"),
        ])
        let manager = TunnelManager(
            transport: transport,
            endpointCache: cache,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        manager.installIntegrationGateRelayOnlyCandidatePolicy()
        await manager.connect()

        XCTAssertEqual(Self.lanCount(transport.capturedCandidates), 0)
        XCTAssertEqual(Self.relayCount(transport.capturedCandidates), 1)
        let summary = try XCTUnwrap(manager.integrationGateCandidateBuildSummary)
        XCTAssertEqual(summary.originalLocalEndpointCount, 1)
        XCTAssertEqual(summary.cachedDirectCandidateCount, 1)
        XCTAssertEqual(summary.bootstrapDirectCandidateCount, 0)
        XCTAssertEqual(summary.returnedDirectCandidateCount, 0)
        XCTAssertEqual(summary.returnedRelayCandidateCount, 1)
        XCTAssertNil(summary.postConnectCachedDirectCandidateCount)
    }

    func testRuntimeLanRepopulationIsRecordedAfterRefresh() async throws {
        IntegrationGateRelayOnlyURLProtocol.reset()
        defer { IntegrationGateRelayOnlyURLProtocol.reset() }
        IntegrationGateRelayOnlyURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/network/local-endpoints")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data("""
            {"local_endpoints":[{"host":"10.0.0.30","port":7657,"scope":"local"}]}
            """.utf8)
            return (response, body)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationGateRelayOnlyURLProtocol.self]
        let cache = EndpointCache(fileURL: Self.tempFileURL(), session: URLSession(configuration: configuration))
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plViaSpl
        let pairing = Self.pairing(localEndpoints: [
            LocalEndpoint(host: "10.0.0.10", port: 7657, scope: "local"),
        ])
        let manager = TunnelManager(
            transport: transport,
            endpointCache: cache,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        manager.installIntegrationGateRelayOnlyCandidatePolicy()
        await manager.connect()

        try await Self.waitForPostConnectDirectCount(manager, expected: 1)
        let summary = try XCTUnwrap(manager.integrationGateCandidateBuildSummary)
        XCTAssertEqual(summary.returnedDirectCandidateCount, 0)
        XCTAssertEqual(summary.postConnectCachedDirectCandidateCount, 1)
        await manager.disconnect()
    }

    func testPairingValidationFailClosedCases() throws {
        let loader = IntegrationGatePairingSnapshotLoader()
        let manifest = Self.manifest()

        XCTAssertThrowsError(try loader.validatedSnapshot(pairing: Self.pairing(instanceID: "foreign"), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .foreignPairing)
        }
        XCTAssertThrowsError(try loader.validatedSnapshot(pairing: Self.pairing(fingerprint: Self.digest("b")), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .foreignPairing)
        }
        XCTAssertThrowsError(try loader.validatedSnapshot(pairing: Self.pairing(pairedAt: Date(timeIntervalSince1970: 0)), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .stalePairing)
        }
        XCTAssertThrowsError(try loader.validatedSnapshot(pairing: Self.pairing(deviceToken: ""), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .absentRelayEnrollment)
        }
        XCTAssertThrowsError(try loader.validatedSnapshot(pairing: Self.pairing(relayEndpoint: "https://example.test"), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .wrongRelayEndpoint)
        }
    }

    private static func manifest() -> IntegrationGateManifest {
        IntegrationGateManifest(
            schemaVersion: IntegrationGateConstants.schemaVersion,
            sequence: 1,
            nonce: "synthetic-gate-nonce",
            action: .canary,
            createdAtUnixMillis: 1,
            expiresAtUnixMillis: 2_000,
            expectedPairing: .init(
                instanceID: "synthetic-gate-instance",
                fingerprintSHA256Hex: Self.digest("a"),
                pairedAtNotBeforeUnixMillis: 1_000
            ),
            expectedBuild: .init(sourceCommit: "synthetic-source", splSwiftRevision: "synthetic-spl"),
            expectedContentLength: nil,
            expectedSHA256Hex: nil,
            rangeStart: nil,
            rangeLength: nil
        )
    }

    private static func pairing(
        instanceID: String = "synthetic-gate-instance",
        fingerprint: String = digest("a"),
        relayEndpoint: String = IntegrationGateConstants.relayEndpoint,
        deviceToken: String = "synthetic-device-token",
        localEndpoints: [LocalEndpoint] = [],
        pairedAt: Date = Date(timeIntervalSince1970: 2)
    ) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "synthetic-home",
            relayEndpoint: relayEndpoint,
            fingerprint: fingerprint,
            clientCertPEM: "synthetic-cert",
            clientKeyPEM: "synthetic-key",
            caChainPEM: "synthetic-ca",
            relayEnrollment: .enrolled(deviceToken: deviceToken, expiresAt: nil),
            localEndpoints: localEndpoints,
            pairedAt: pairedAt
        )
    }

    private static func lanCount(_ candidates: [TransportEndpoint]) -> Int {
        candidates.filter {
            if case .lan = $0 {
                return true
            }
            return false
        }.count
    }

    private static func relayCount(_ candidates: [TransportEndpoint]) -> Int {
        candidates.filter {
            if case .relay = $0 {
                return true
            }
            return false
        }.count
    }

    private static func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    private static func waitForPostConnectDirectCount(_ manager: TunnelManager, expected: Int) async throws {
        for _ in 0..<50 {
            if manager.integrationGateCandidateBuildSummary?.postConnectCachedDirectCandidateCount == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for post-connect direct candidate count")
    }
}

private final class IntegrationGateRelayOnlyURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static func reset() {
        self.handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("integration gate relay-only url protocol handler missing")
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
