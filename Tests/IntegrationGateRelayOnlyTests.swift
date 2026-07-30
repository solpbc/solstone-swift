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

    func testRelayOnlyPolicyPreservesPairingDuringInjectedRevocation() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        let pairing = Self.pairing()
        await cache.bootstrap(from: pairing)
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plViaSpl
        transport.nextResult = .failure(.revoked)
        let manager = TunnelManager(
            transport: transport,
            endpointCache: cache,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {
                didDeletePairing.withLock { $0 = true }
            }
        )

        manager.installIntegrationGateRelayOnlyCandidatePolicy()
        await manager.connect()

        XCTAssertEqual(manager.state, .error(.revoked))
        XCTAssertFalse(didDeletePairing.withLock { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
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

        let result = await Self.actionResult(manager: manager, action: .syncReconnectWindow)
        XCTAssertEqual(result.verdict, .fail)
        XCTAssertEqual(result.reasonCode, .runtimeLanRepopulation)
        await manager.disconnect()
    }

    func testPairingValidationFailClosedCases() throws {
        let loader = IntegrationGatePairingSnapshotLoader()
        let manifest = Self.manifest()

        let store = SPLKeychainStore(
            policy: KeychainPolicy(
                service: "app.solstone.swift.tests.integration-gate.\(UUID().uuidString)",
                account: "zero-pairing",
                accessGroup: nil,
                useDataProtectionKeychain: false,
                accessibility: .afterFirstUnlock
            )
        )
        defer { try? store.delete() }
        try? store.delete()
        XCTAssertThrowsError(try loader.loadValidatedPairing(for: manifest, keychainStore: store)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .zeroPairing)
        }

        let original = try loader.validatedSnapshot(pairing: Self.pairing(), manifest: manifest)
        XCTAssertThrowsError(try loader.validateUnchanged(original: original, pairing: Self.pairing(relayEndpoint: "https://example.test"), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .changedPairing)
        }

        XCTAssertThrowsError(try loader.validatedSnapshot(pairing: Self.pairing(instanceID: "foreign"), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .foreignPairing)
        }
        XCTAssertThrowsError(try loader.validatedSnapshot(pairing: Self.pairing(caChainPEM: CertlessTrustFixtures.wrongCAPEM), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .foreignPairing)
        }
        XCTAssertThrowsError(try loader.validateUnchanged(original: original, pairing: Self.pairing(fingerprint: Self.digest("b")), manifest: manifest)) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .changedPairing)
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

    func testG4AndG5ActionVerdictsFailWhenLanEndpointIsSelected() async throws {
        IntegrationGateRelayOnlyURLProtocol.reset()
        defer { IntegrationGateRelayOnlyURLProtocol.reset() }
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        let cache = EndpointCache(fileURL: Self.tempFileURL(), session: Self.emptyLocalEndpointsSession())
        let pairing = Self.pairing()
        let manager = TunnelManager(
            transport: transport,
            endpointCache: cache,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        manager.installIntegrationGateRelayOnlyCandidatePolicy()
        await manager.connect()

        // connect() spawns a detached post-connect endpoint-cache refresh that issues the
        // only request routed through IntegrationGateRelayOnlyURLProtocol here. The summary
        // records postConnectCachedDirectCandidateCount strictly after that refresh returns,
        // so waiting for it proves the request is done and cannot outlive the deferred
        // handler reset and trip the unstubbed-request tripwire during a later test.
        try await Self.waitForPostConnectDirectCount(manager, expected: 0)

        let reconnect = await Self.actionResult(manager: manager, action: .syncReconnectWindow)
        XCTAssertEqual(reconnect.verdict, .fail)
        XCTAssertEqual(reconnect.reasonCode, .selectedLanEndpoint)

        let transfer = await Self.actionResult(manager: manager, action: .syncTransferWindow)
        XCTAssertEqual(transfer.verdict, .fail)
        XCTAssertEqual(transfer.reasonCode, .selectedLanEndpoint)
        await manager.disconnect()
    }

    private static func manifest(action: IntegrationGateAction = .canary) -> IntegrationGateManifest {
        IntegrationGateManifest(
            schemaVersion: IntegrationGateConstants.schemaVersion,
            sequence: 1,
            nonce: "synthetic-gate-nonce",
            action: action,
            createdAtUnixMillis: 1,
            expiresAtUnixMillis: 2_000,
            expectedPairing: .init(
                instanceID: "synthetic-gate-instance",
                fingerprintSHA256Hex: Self.caFingerprint,
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
        caChainPEM: String = CertlessTrustFixtures.caPEM,
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
            caChainPEM: caChainPEM,
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

    private static var caFingerprint: String {
        let certificate = try! XCTUnwrap(
            CertChain.certificates(fromPEM: CertlessTrustFixtures.caPEM).first
        )
        return CertChain.sha256Fingerprint(of: certificate)
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    private static func emptyLocalEndpointsSession() -> URLSession {
        IntegrationGateRelayOnlyURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"local_endpoints":[]}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationGateRelayOnlyURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func actionResult(
        manager: TunnelManager,
        action: IntegrationGateAction
    ) async -> IntegrationGateActionRunResult {
        let clock = MockObserverClock()
        let httpClient = IntegrationGateHTTPClient(
            tunnelManager: manager,
            session: Self.emptyLocalEndpointsSession(),
            now: { clock.now() }
        )
        let sync = ConnectionSyncModel(clock: clock) {
            ConnectionSyncInputs(
                tunnelState: manager.state,
                reconnectCountdown: manager.reconnectCountdown,
                isNetworkSatisfied: manager.isNetworkSatisfied,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        }
        let sampler = IntegrationGateSampler(
            tunnelManager: manager,
            connectionSyncModel: sync,
            httpClient: httpClient,
            clock: clock
        )
        let actions = IntegrationGateActions(
            tunnelManager: manager,
            httpClient: httpClient,
            sampler: sampler,
            clock: clock,
            writeRunning: { _ in }
        )
        return await actions.run(manifest: Self.manifest(action: action))
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
