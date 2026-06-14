// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest
import os

private final class MockPathSource: PathMonitoringSource, @unchecked Sendable {
    var handler: (@Sendable () -> Void)?
    var startCount = 0
    var stopCount = 0

    func start(onPathChange: @Sendable @escaping () -> Void) {
        startCount += 1
        handler = onPathChange
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func trigger() {
        handler?()
    }
}

nonisolated final class TunnelManagerTests: XCTestCase {
    @MainActor private func makeManager(
        transport: MockCFTunnelTransport,
        endpointCache: EndpointCache? = nil,
        pathMonitor: PathMonitor = PathMonitor(),
        pairing: StoredPairing? = fixturePairing(),
        didDeletePairing: OSAllocatedUnfairLock<Bool>? = nil,
        initialRetryDelay: TimeInterval = 10
    ) -> TunnelManager {
        TunnelManager(
            transport: transport,
            endpointCache: endpointCache ?? EndpointCache(fileURL: Self.tempFileURL()),
            pathMonitor: pathMonitor,
            loadPairing: { pairing },
            deletePairing: { didDeletePairing?.withLock { $0 = true } },
            initialRetryDelay: initialRetryDelay
        )
    }

    @MainActor
    func testSuccessfulDirectConnectPublishesLoopbackPort() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        transport.nextResult = .success(8080)
        let cache = EndpointCache(fileURL: Self.tempFileURL())
        await cache.bootstrap(from: Self.fixturePairing())
        let manager = makeManager(transport: transport, endpointCache: cache)

        await manager.connect()

        XCTAssertEqual(manager.state, .connected(localPort: 8080, via: .lan))
        XCTAssertEqual(transport.capturedCandidates.count, 2)
    }

    @MainActor
    func testCandidateListIncludesBootstrapLocalsWhenCacheEmpty() async {
        let transport = MockCFTunnelTransport()
        let pairing = Self.fixturePairing(localEndpoints: [
            Self.localEndpoint(host: "10.0.0.10", port: 7657, scope: "local"),
            Self.localEndpoint(host: "fd12::1", port: 7657, scope: "ula"),
        ])
        let manager = makeManager(
            transport: transport,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            pairing: pairing
        )

        await manager.connect()

        XCTAssertEqual(Self.lanCandidates(from: transport.capturedCandidates), [
            .lan(host: "10.0.0.10", port: 7657, scope: "local"),
            .lan(host: "fd12::1", port: 7657, scope: "ula"),
        ])
        XCTAssertEqual(Self.relayCandidateCount(from: transport.capturedCandidates), 1)
    }

    @MainActor
    func testCandidateListDedupesCacheAndBootstrapLocalsWithCacheFirst() async {
        let transport = MockCFTunnelTransport()
        let cachePairing = Self.fixturePairing(localEndpoints: [
            Self.localEndpoint(host: "10.0.0.10", port: 7657, scope: "local"),
        ])
        let cache = EndpointCache(fileURL: Self.tempFileURL())
        await cache.bootstrap(from: cachePairing)
        let pairing = Self.fixturePairing(localEndpoints: [
            Self.localEndpoint(host: "10.0.0.10", port: 7657, scope: "local"),
            Self.localEndpoint(host: "fd12::1", port: 7657, scope: "ula"),
        ])
        let manager = makeManager(transport: transport, endpointCache: cache, pairing: pairing)

        await manager.connect()

        XCTAssertEqual(Self.lanCandidates(from: transport.capturedCandidates), [
            .lan(host: "10.0.0.10", port: 7657, scope: "local"),
            .lan(host: "fd12::1", port: 7657, scope: "ula"),
        ])
        XCTAssertEqual(Self.relayCandidateCount(from: transport.capturedCandidates), 1)
    }

    @MainActor
    func testCandidateListFallsBackToRelayWhenNoLocalEndpointsExist() async {
        let transport = MockCFTunnelTransport()
        let pairing = Self.fixturePairing(localEndpoints: [])
        let manager = makeManager(
            transport: transport,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            pairing: pairing
        )

        await manager.connect()

        XCTAssertEqual(Self.lanCandidates(from: transport.capturedCandidates), [])
        XCTAssertEqual(Self.relayCandidateCount(from: transport.capturedCandidates), 1)
    }

    @MainActor
    func testCandidateListOmitsRelayWhenDeviceTokenIsEmpty() async {
        let transport = MockCFTunnelTransport()
        let pairing = Self.fixturePairing(deviceToken: "")
        let manager = makeManager(
            transport: transport,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            pairing: pairing
        )

        await manager.connect()

        XCTAssertEqual(Self.lanCandidates(from: transport.capturedCandidates), [
            .lan(host: "127.0.0.1", port: 8676, scope: ""),
        ])
        XCTAssertEqual(Self.relayCandidateCount(from: transport.capturedCandidates), 0)
    }

    @MainActor
    func testSuccessfulRelayConnectPublishesLoopbackPort() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plViaSpl
        transport.nextResult = .success(9090)
        let manager = makeManager(transport: transport)

        await manager.connect()

        XCTAssertEqual(manager.state, .connected(localPort: 9090, via: .remote))
        XCTAssertEqual(transport.connectionMode, .plViaSpl)
    }

    @MainActor
    func testUnreachablePropagatesAsUIError() async {
        let transport = MockCFTunnelTransport()
        transport.nextResult = .failure(.unreachable)
        let manager = makeManager(transport: transport)

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertEqual(transport.disconnectCallCount, 1)
    }

    @MainActor
    func testRevokedWipesPairingAndEndpointCache() async {
        let didDelete = OSAllocatedUnfairLock(initialState: false)
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.fixturePairing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let transport = MockCFTunnelTransport()
        transport.nextResult = .failure(.revoked)
        let manager = makeManager(
            transport: transport,
            endpointCache: cache,
            didDeletePairing: didDelete
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.revoked))
        XCTAssertTrue(didDelete.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testReconnectAfterOnDisconnect() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        let manager = makeManager(transport: transport)

        await manager.connect()
        transport.simulateDisconnect(error: TunnelError.muxTeardown)
        await Self.settle()

        XCTAssertEqual(manager.state, .error(.muxTeardown))
        XCTAssertNotNil(manager.reconnectCountdown)
    }

    @MainActor
    func testPathChangeTriggersFreshRace() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)

        await manager.connect()
        XCTAssertEqual(transport.connectCallCount, 1)

        manager.startNetworkMonitoring()
        source.trigger()
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertGreaterThanOrEqual(transport.disconnectCallCount, 1)
        XCTAssertEqual(transport.connectCallCount, 2)
    }

    @MainActor
    func testStatePreservationAcrossReconnects() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        transport.nextResult = .success(1111)
        let manager = makeManager(transport: transport)

        await manager.connect()
        XCTAssertEqual(manager.state, .connected(localPort: 1111, via: .lan))

        await manager.disconnect()
        transport.connectionMode = .plViaSpl
        transport.nextResult = .success(2222)
        await manager.connect()

        XCTAssertEqual(manager.state, .connected(localPort: 2222, via: .remote))
    }

    private static func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("endpoints.json")
    }

    private static func fixturePairing(
        localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "127.0.0.1", port: 8676, scope: "")],
        deviceToken: String = "device-token"
    ) -> StoredPairing {
        StoredPairing(
            instanceID: "instance-123",
            homeLabel: "sol",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: "ca",
            relayEnrollment: .enrolled(deviceToken: deviceToken),
            localEndpoints: localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }

    private static func localEndpoint(host: String, port: Int, scope: String) -> LocalEndpoint {
        LocalEndpoint(host: host, port: port, scope: scope)
    }

    private static func lanCandidates(from candidates: [TransportEndpoint]) -> [TransportEndpoint] {
        candidates.filter { endpoint in
            if case .lan = endpoint {
                return true
            }
            return false
        }
    }

    private static func relayCandidateCount(from candidates: [TransportEndpoint]) -> Int {
        candidates.filter { endpoint in
            if case .relay = endpoint {
                return true
            }
            return false
        }.count
    }
}
