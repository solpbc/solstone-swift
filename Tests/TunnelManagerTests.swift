// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
// Reaches SPLTunnel package internals; relies on Xcode compiling SPM products with testability in Debug.
@testable import SPLTunnel
import XCTest
import os

private final class MockPathSource: PathMonitoringSource, @unchecked Sendable {
    var handler: (@Sendable (NetworkPathStatus) -> Void)?
    var startCount = 0
    var stopCount = 0

    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        startCount += 1
        handler = onPathChange
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func trigger(_ status: NetworkPathStatus = .satisfiedWiFi) {
        handler?(status)
    }
}

nonisolated final class TunnelManagerTests: XCTestCase {
    @MainActor private func makeManager(
        transport: any Transporting,
        endpointCache: EndpointCache? = nil,
        pathMonitor: PathMonitor = PathMonitor(),
        pairing: StoredPairing? = fixturePairing(),
        loadPairing: (@Sendable () throws -> StoredPairing?)? = nil,
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { _ in },
        didDeletePairing: OSAllocatedUnfairLock<Bool>? = nil,
        deviceTokenRefresher: DeviceTokenRefresher = DeviceTokenRefresher(clientInfo: SPLRuntime.clientInfo),
        initialRetryDelay: TimeInterval = 10,
        connectDeadline: Duration = .seconds(15),
        waitingDeadline: Duration = .seconds(600),
        probeSession: URLSession = .shared,
        probeURLBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            URL(string: "http://127.0.0.1:\(localPort)/app/network/api/status")
        },
        probeInterval: Duration = .seconds(15),
        probeFailureThreshold: Int = 2,
        activeLocalTransferCountProvider: @escaping @Sendable @MainActor () -> Int = { 0 },
        diagnosticLog: DiagnosticLog? = nil
    ) -> TunnelManager {
        TunnelManager(
            transport: transport,
            endpointCache: endpointCache ?? EndpointCache(fileURL: Self.tempFileURL()),
            pathMonitor: pathMonitor,
            loadPairing: loadPairing ?? { pairing },
            savePairing: savePairing,
            deletePairing: { didDeletePairing?.withLock { $0 = true } },
            deviceTokenRefresher: deviceTokenRefresher,
            initialRetryDelay: initialRetryDelay,
            connectDeadline: connectDeadline,
            waitingDeadline: waitingDeadline,
            probeSession: probeSession,
            probeURLBuilder: probeURLBuilder,
            probeInterval: probeInterval,
            probeFailureThreshold: probeFailureThreshold,
            activeLocalTransferCountProvider: activeLocalTransferCountProvider,
            diagnosticLog: diagnosticLog
        )
    }

    @MainActor
    func testOwnerPairingCompletionArmsOwnerConnectSuccessBanner() {
        let manager = TunnelManager()

        XCTAssertFalse(manager.ownerConnectSuccessBannerArmedForTesting)
        OwnerPairingCompletion.completeOwnerPairing(tunnelManager: manager)
        XCTAssertTrue(manager.ownerConnectSuccessBannerArmedForTesting)
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
    func testConnectionEpochTracksSuccessfulConnectionsAndHidesWhenInactive() async throws {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        transport.nextResult = .success(1111)
        let manager = makeManager(transport: transport)

        XCTAssertEqual(manager.connectionEpoch, 0)
        XCTAssertNil(manager.activeConnection)

        await manager.connect()

        XCTAssertEqual(manager.connectionEpoch, 1)
        let first = try XCTUnwrap(manager.activeConnection)
        XCTAssertEqual(first.port, 1111)
        XCTAssertEqual(first.epoch, 1)

        await manager.disconnect()

        XCTAssertEqual(manager.connectionEpoch, 1)
        XCTAssertNil(manager.activeConnection)

        transport.connectionMode = .plViaSpl
        transport.nextResult = .success(1111)
        await manager.connect()

        XCTAssertEqual(manager.connectionEpoch, 2)
        let second = try XCTUnwrap(manager.activeConnection)
        XCTAssertEqual(second.port, 1111)
        XCTAssertEqual(second.epoch, 2)
        await manager.disconnect()
    }

    @MainActor
    func testForceConnectedAdvancesConnectionEpoch() throws {
        let manager = makeManager(transport: MockCFTunnelTransport())

        manager.forceConnected(port: 8080, via: .lan)

        XCTAssertEqual(manager.connectionEpoch, 1)
        let first = try XCTUnwrap(manager.activeConnection)
        XCTAssertEqual(first.port, 8080)
        XCTAssertEqual(first.epoch, 1)

        manager.forceConnected(port: 8080, via: .lan)

        XCTAssertEqual(manager.connectionEpoch, 2)
        let second = try XCTUnwrap(manager.activeConnection)
        XCTAssertEqual(second.port, 8080)
        XCTAssertEqual(second.epoch, 2)
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
    func testPreDialRefreshUsesFreshRelayTokenAndSavesPairing() async {
        let oldToken = "bad-token"
        let newToken = Self.validFutureDeviceToken + "x"
        let original = Self.fixturePairing(localEndpoints: [], deviceToken: oldToken)
        let saved = OSAllocatedUnfairLock<StoredPairing?>(initialState: nil)
        let transport = MockCFTunnelTransport()
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(responseData: Self.tokenRefreshSuccessData(deviceToken: newToken)),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            pairing: original,
            savePairing: { updated in saved.withLock { $0 = updated } },
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(saved.withLock { $0?.relayEnrollment }, .enrolled(deviceToken: newToken, expiresAt: "2036-01-01T00:00:00Z"))
        XCTAssertEqual(Self.relayTokens(from: transport.capturedCandidates), [newToken])
    }

    @MainActor
    func testReactiveTokenExpiredRefreshesAndRedialsOnce() async {
        let newToken = Self.validFutureDeviceToken + "x"
        let pairingBox = OSAllocatedUnfairLock(initialState: Self.fixturePairing(localEndpoints: [], deviceToken: Self.validFutureDeviceToken))
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.authRefreshRequired),
            .success(8181),
        ]
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(responseData: Self.tokenRefreshSuccessData(deviceToken: newToken)),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            loadPairing: { pairingBox.withLock { $0 } },
            savePairing: { updated in pairingBox.withLock { $0 = updated } },
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .connected(localPort: 8181, via: .remote))
        XCTAssertEqual(transport.connectCallCount, 2)
        XCTAssertEqual(TunnelTokenRefreshURLProtocol.requestURLs(), ["https://relay.example.com/token/refresh"])
        XCTAssertEqual(Self.relayTokens(from: transport.capturedCandidateBatches.last ?? []), [newToken])
    }

    @MainActor
    func testReactiveTokenExpiredSecondFailureIsTerminalRevoked() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let pairingBox = OSAllocatedUnfairLock(initialState: Self.fixturePairing(localEndpoints: [], deviceToken: Self.validFutureDeviceToken))
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.authRefreshRequired),
            .failure(SessionError.authRefreshRequired),
        ]
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(responseData: Self.tokenRefreshSuccessData()),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            loadPairing: { pairingBox.withLock { $0 } },
            savePairing: { updated in pairingBox.withLock { $0 = updated } },
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.revoked))
        XCTAssertEqual(transport.connectCallCount, 2)
        XCTAssertEqual(TunnelTokenRefreshURLProtocol.requestURLs().count, 1)
        XCTAssertTrue(didDeletePairing.withLock { $0 })
    }

    @MainActor
    func testReactiveTokenExpiredNotNeededStaysRetryable() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let enrolledPairing = Self.fixturePairing(localEndpoints: [])
        let nonEnrolledPairing = StoredPairing(
            instanceID: enrolledPairing.instanceID,
            homeLabel: enrolledPairing.homeLabel,
            relayEndpoint: enrolledPairing.relayEndpoint,
            fingerprint: enrolledPairing.fingerprint,
            clientCertPEM: enrolledPairing.clientCertPEM,
            clientKeyPEM: enrolledPairing.clientKeyPEM,
            caChainPEM: enrolledPairing.caChainPEM,
            relayEnrollment: .unavailable,
            localEndpoints: enrolledPairing.localEndpoints,
            pairedAt: enrolledPairing.pairedAt
        )
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.authRefreshRequired),
        ]
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            loadPairing: {
                let count = loadCount.withLock { value in
                    let current = value
                    value += 1
                    return current
                }
                return count == 0 ? enrolledPairing : nonEnrolledPairing
            },
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertEqual(TunnelTokenRefreshURLProtocol.requestURLs().count, 0)
        XCTAssertFalse(didDeletePairing.withLock { $0 })
    }

    @MainActor
    func testHandshakeRevokedRefreshesThenRetriesStaysRetryable() async {
        let newToken = Self.validFutureDeviceToken + "x"
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.fixturePairing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.revoked),
            .failure(SessionError.revoked),
        ]
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(responseData: Self.tokenRefreshSuccessData(deviceToken: newToken)),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            endpointCache: cache,
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        // Handshake 401 and 403 both surface as SessionError.revoked here, so this covers both.
        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertEqual(transport.connectCallCount, 2)
        XCTAssertEqual(TunnelTokenRefreshURLProtocol.requestURLs().count, 1)
        XCTAssertFalse(didDeletePairing.withLock { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testHandshakeRevokedBodyConfirmedRevocationDestroys() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.fixturePairing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.revoked),
        ]
        let refresher = DeviceTokenRefresher(session: Self.tokenRefreshSession(
            responseData: Data(#"{"error":"instance revoked"}"#.utf8),
            statusCode: 403
        ), clientInfo: SPLRuntime.clientInfo)
        let manager = makeManager(
            transport: transport,
            endpointCache: cache,
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.revoked))
        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertTrue(didDeletePairing.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testHandshakeRevokedExpiredReasonRevocationDestroys() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.fixturePairing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.revoked),
        ]
        let refresher = DeviceTokenRefresher(session: Self.tokenRefreshSession(
            responseData: Data(#"{"error":"invalid device_token","reason":"expired"}"#.utf8),
            statusCode: 401
        ), clientInfo: SPLRuntime.clientInfo)
        let manager = makeManager(
            transport: transport,
            endpointCache: cache,
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.revoked))
        XCTAssertTrue(didDeletePairing.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testHandshakeRevokedWafCoincidenceStaysRetryable() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.fixturePairing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let transport = MockCFTunnelTransport()
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(statusCode: 403),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            endpointCache: cache,
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        for _ in 0..<3 {
            transport.queuedResults = [
                .failure(SessionError.revoked),
            ]
            await manager.connect()
            XCTAssertEqual(manager.state, .error(.unreachable))
        }

        XCTAssertEqual(transport.connectCallCount, 3)
        XCTAssertFalse(didDeletePairing.withLock { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testHandshakeRevoked404StaysRetryable() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.fixturePairing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.revoked),
        ]
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(statusCode: 404),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            endpointCache: cache,
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertFalse(didDeletePairing.withLock { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testHandshakeRevokedNotNeededStaysRetryable() async {
        let didDeletePairing = OSAllocatedUnfairLock(initialState: false)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let enrolledPairing = Self.fixturePairing()
        let nonEnrolledPairing = StoredPairing(
            instanceID: enrolledPairing.instanceID,
            homeLabel: enrolledPairing.homeLabel,
            relayEndpoint: enrolledPairing.relayEndpoint,
            fingerprint: enrolledPairing.fingerprint,
            clientCertPEM: enrolledPairing.clientCertPEM,
            clientKeyPEM: enrolledPairing.clientKeyPEM,
            caChainPEM: enrolledPairing.caChainPEM,
            relayEnrollment: .unavailable,
            localEndpoints: enrolledPairing.localEndpoints,
            pairedAt: enrolledPairing.pairedAt
        )
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: enrolledPairing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let transport = MockCFTunnelTransport()
        transport.queuedResults = [
            .failure(SessionError.revoked),
        ]
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            endpointCache: cache,
            loadPairing: {
                let count = loadCount.withLock { value in
                    let current = value
                    value += 1
                    return current
                }
                return count == 0 ? enrolledPairing : nonEnrolledPairing
            },
            didDeletePairing: didDeletePairing,
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertEqual(TunnelTokenRefreshURLProtocol.requestURLs().count, 0)
        XCTAssertFalse(didDeletePairing.withLock { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testMissingPairingAtConnectTerminatesRevoked() async {
        let transport = MockCFTunnelTransport()
        let refresher = DeviceTokenRefresher(
            session: Self.tokenRefreshSession(),
            clientInfo: SPLRuntime.clientInfo
        )
        let manager = makeManager(
            transport: transport,
            loadPairing: { nil },
            deviceTokenRefresher: refresher
        )

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.revoked))
        XCTAssertEqual(transport.connectCallCount, 0)
        XCTAssertEqual(TunnelTokenRefreshURLProtocol.requestURLs().count, 0)
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
    func testReconnectCountBucketTransportClosed() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        let manager = makeManager(transport: transport)

        await manager.connect()
        transport.simulateDisconnect(error: TunnelError.muxTeardown)
        let didSchedule = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didSchedule)

        await manager.retryNow()

        Self.assertReconnectBuckets(manager, expected: [.transportClosed: 1])
        await manager.disconnect()
    }

    @MainActor
    func testReconnectCountBucketKeepaliveMissed() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        let manager = makeManager(transport: transport)

        await manager.connect()
        transport.simulateDisconnect(error: SessionError.directKeepaliveMissed)
        let didSchedule = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didSchedule)

        await manager.retryNow()

        Self.assertReconnectBuckets(manager, expected: [.keepaliveMissed: 1])
        await manager.disconnect()
    }

    @MainActor
    func testReconnectCountBucketPathChanged() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)

        await manager.connect()
        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        let didApplyWiFiBaseline = await Self.waitUntil {
            manager.currentPathStatus == .satisfiedWiFi
        }
        XCTAssertTrue(didApplyWiFiBaseline)

        source.trigger(NetworkPathStatus(
            isSatisfied: true,
            isWiFi: false,
            isCellular: true,
            isExpensive: false,
            isConstrained: false
        ))
        let didSchedule = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didSchedule)

        await manager.retryNow()

        Self.assertReconnectBuckets(manager, expected: [.pathChanged: 1])
        manager.stopNetworkMonitoring()
        await manager.disconnect()
    }

    @MainActor
    func testReconnectCountBucketProbeFailed() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = makeManager(
            transport: transport,
            probeSession: session,
            probeInterval: .milliseconds(20),
            probeFailureThreshold: 1
        )

        await manager.connect()
        let didSchedule = await Self.waitUntil({
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }, timeout: .seconds(2))
        XCTAssertTrue(didSchedule)

        TunnelProbeURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        await manager.retryNow()

        Self.assertReconnectBuckets(manager, expected: [.probeFailed: 1])
        await manager.disconnect()
    }

    @MainActor
    func testReconnectCountTotalEqualsSumAcrossMixedSequence() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        transport.suspendConnectUntilDisconnect = true
        let manager = makeManager(
            transport: transport,
            pathMonitor: pathMonitor,
            connectDeadline: .milliseconds(100)
        )

        let timeoutConnectTask = Task { @MainActor in
            await manager.connect()
        }
        let didTimeout = await Self.waitUntil {
            if case .error(.unreachable) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didTimeout)
        await timeoutConnectTask.value

        transport.suspendConnectUntilDisconnect = false
        transport.nextResult = .success(1111)
        await manager.retryNow()
        XCTAssertEqual(manager.state, .connected(localPort: 1111, via: .lan))

        transport.queuedResults = [
            .failure(TunnelError.unreachable),
            .success(2222),
        ]
        transport.simulateDisconnect(error: TunnelError.muxTeardown)
        let didScheduleTransportClosed = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didScheduleTransportClosed)

        await manager.retryNow()
        XCTAssertEqual(manager.state, .error(.unreachable))
        await manager.retryNow()
        XCTAssertEqual(manager.state, .connected(localPort: 2222, via: .lan))

        transport.nextResult = .success(3333)
        transport.simulateDisconnect(error: SessionError.directKeepaliveMissed)
        let didScheduleKeepalive = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didScheduleKeepalive)
        await manager.retryNow()
        XCTAssertEqual(manager.state, .connected(localPort: 3333, via: .lan))

        transport.simulateDisconnect(error: TunnelError.muxTeardown)
        let didScheduleBeforePathRestore = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didScheduleBeforePathRestore)
        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        let didApplyPathRestore = await Self.waitUntil({
            manager.currentPathStatus == .satisfiedWiFi
        }, timeout: .seconds(2))
        XCTAssertTrue(didApplyPathRestore)
        transport.nextResult = .success(4444)
        await manager.retryNow()
        XCTAssertEqual(manager.state, .connected(localPort: 4444, via: .lan))

        Self.assertReconnectBuckets(manager, expected: [
            .transportClosed: 1,
            .keepaliveMissed: 1,
            .connectFailed: 1,
            .watchdogTimeout: 1,
            .pathRestore: 1,
        ])
        manager.stopNetworkMonitoring()
        await manager.disconnect()
    }

    @MainActor
    func testRealCFTunnelTransportSessionFailureForcesManagerReconnect() async {
        let pairing = Self.fixturePairing()
        let fakeSession = FakeTunnelSession()
        let transport = CFTunnelTransport(
            loadPairing: { pairing },
            makeSession: { _ in fakeSession }
        )
        let manager = makeManager(transport: transport, pairing: pairing)

        await manager.connect()
        guard case .connected = manager.state else {
            XCTFail("expected connected state")
            return
        }

        await fakeSession.pushFailed(.transportFailed("pump ended"))

        let didSchedule = await Self.waitUntil {
            if case .error(.unreachable) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didSchedule)
        let fakeConnectCallCount = await fakeSession.connectCallCount
        XCTAssertEqual(fakeConnectCallCount, 1)
        await manager.disconnect()
    }

    @MainActor
    func testTerminalDuringConnectSchedulesReconnectWithoutPublishingConnected() async {
        let pairing = Self.fixturePairing()
        let fakeSession = FakeTunnelSession(failureDuringConnect: .transportFailed("pump ended during connect"))
        let transport = CFTunnelTransport(
            loadPairing: { pairing },
            makeSession: { _ in fakeSession }
        )
        let manager = makeManager(transport: transport, pairing: pairing)

        await manager.connect()

        if case .connected = manager.state {
            XCTFail("manager must not publish connected after a connect-window terminal")
        }
        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertNotNil(manager.reconnectCountdown)
        await manager.disconnect()
    }

    @MainActor
    func testMapTransportErrorInboundFaultUnchanged() {
        let manager = makeManager(transport: MockCFTunnelTransport())

        let inboundClosed = manager.mapTransportError(SessionError.inboundClosed(fault: "streamReset(streamID: 3)"))
        let transportFailed = manager.mapTransportError(SessionError.transportFailed("inbound closed"))

        XCTAssertEqual(inboundClosed, .unreachable)
        XCTAssertEqual(inboundClosed, transportFailed)
        XCTAssertEqual(inboundClosed.userMessage, transportFailed.userMessage)
        XCTAssertEqual(inboundClosed.isRetryable, transportFailed.isRetryable)
    }

    @MainActor
    func testInboundClosedFaultAggregatesBeforeTransportMapping() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        let manager = makeManager(transport: transport)

        await manager.connect()
        transport.simulateDisconnect(error: SessionError.inboundClosed(fault: "streamReset(streamID: 3)"))

        let didAggregate = await Self.waitUntil {
            manager.inboundClosedFaultCounts["streamReset(streamID: 3)"] == 1
        }
        XCTAssertTrue(didAggregate)
        XCTAssertEqual(manager.state, .error(.unreachable))
        await manager.disconnect()
    }

    @MainActor
    func testConnectingWatchdogDisconnectsWhileStillConnecting() async {
        let transport = MockCFTunnelTransport()
        transport.suspendConnectUntilDisconnect = true
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(
            transport: transport,
            connectDeadline: .milliseconds(200),
            diagnosticLog: diagnosticLog
        )
        var wasConnectingAtDisconnect = false
        transport.onDisconnectInvoked = {
            if case .connecting = manager.state {
                wasConnectingAtDisconnect = true
            }
        }

        let connectTask = Task { @MainActor in
            await manager.connect()
        }
        let didTimeout = await Self.waitUntil {
            if case .error(.unreachable) = manager.state {
                return true
            }
            return false
        }
        guard didTimeout else {
            connectTask.cancel()
            await manager.disconnect()
            XCTFail("watchdog did not time out")
            return
        }
        await connectTask.value
        await Self.settle()

        XCTAssertTrue(wasConnectingAtDisconnect)
        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertNotNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.disconnectCallCount, 1)
        XCTAssertNil(transport.returnedPort)
        await manager.disconnect()
    }

    @MainActor
    func testConnectingWatchdogTimeoutIsIdempotentAfterSuspendedConnectThrows() async {
        let transport = MockCFTunnelTransport()
        transport.suspendConnectUntilDisconnect = true
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(
            transport: transport,
            connectDeadline: .milliseconds(200),
            diagnosticLog: diagnosticLog
        )

        let connectTask = Task { @MainActor in
            await manager.connect()
        }
        let didTimeout = await Self.waitUntil {
            if case .error(.unreachable) = manager.state {
                return true
            }
            return false
        }
        guard didTimeout else {
            connectTask.cancel()
            await manager.disconnect()
            XCTFail("watchdog did not time out")
            return
        }
        await connectTask.value
        await Self.settle()

        let timeoutEvents = diagnosticLog.events.filter {
            $0.category == .tunnel && $0.severity == .warning && $0.message == "connection timed out"
        }
        let connectionFailedEvents = diagnosticLog.events.filter {
            $0.category == .tunnel && $0.message == "connection failed"
        }
        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertNotNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.disconnectCallCount, 1)
        XCTAssertEqual(timeoutEvents.count, 1)
        XCTAssertEqual(connectionFailedEvents.count, 0)
        await manager.disconnect()
    }

    @MainActor
    func testFastSuccessfulConnectCancelsWatchdog() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        transport.nextResult = .success(6060)
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(
            transport: transport,
            connectDeadline: .milliseconds(200),
            diagnosticLog: diagnosticLog
        )

        await manager.connect()
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertEqual(manager.state, .connected(localPort: 6060, via: .lan))
        XCTAssertEqual(transport.disconnectCallCount, 0)
        XCTAssertNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.returnedPort, 6060)
        XCTAssertFalse(diagnosticLog.events.contains { $0.message == "connection timed out" })
    }

    @MainActor
    func testAwaitingBrokerDisarmsConnectWatchdogAndCanLaterConnect() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plViaSpl
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(
            transport: transport,
            connectDeadline: .milliseconds(100),
            waitingDeadline: .seconds(1)
        )

        let connectTask = Task { @MainActor in
            await manager.connect()
        }
        let didEnterWait = await Self.waitUntil {
            manager.state == .waitingForHome
        }
        XCTAssertTrue(didEnterWait)
        try? await Task.sleep(for: .milliseconds(180))
        await Self.settle()

        XCTAssertEqual(manager.state, .waitingForHome)
        XCTAssertEqual(transport.disconnectCallCount, 0)

        transport.completeSuspendedConnect(port: 4242)
        await connectTask.value

        XCTAssertEqual(manager.state, .connected(localPort: 4242, via: .remote))
        await manager.disconnect()
    }

    @MainActor
    func testAwaitingBrokerTimeoutKeepsWaitingAndSchedulesFixedRedial() async {
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(
            transport: transport,
            initialRetryDelay: 10,
            connectDeadline: .seconds(1),
            waitingDeadline: .milliseconds(100)
        )

        let connectTask = Task { @MainActor in
            await manager.connect()
        }
        let didEnterWait = await Self.waitUntil {
            manager.state == .waitingForHome
        }
        XCTAssertTrue(didEnterWait)
        let didScheduleRelaxedRedial = await Self.waitUntil({
            manager.state == .waitingForHome
                && manager.reconnectCountdown == 60
                && transport.disconnectCallCount == 1
        }, timeout: .seconds(2))
        XCTAssertTrue(didScheduleRelaxedRedial)
        await connectTask.value

        XCTAssertEqual(manager.state, .waitingForHome)
        XCTAssertEqual(manager.reconnectCountdown, 60)
        await manager.disconnect()
    }

    @MainActor
    func testAwaitingBrokerDropRoutesToBackoffReconnect() async {
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(
            transport: transport,
            initialRetryDelay: 1,
            connectDeadline: .seconds(1),
            waitingDeadline: .seconds(1)
        )

        let connectTask = Task { @MainActor in
            await manager.connect()
        }
        let didEnterWait = await Self.waitUntil {
            manager.state == .waitingForHome
        }
        XCTAssertTrue(didEnterWait)

        transport.failSuspendedConnect(error: SessionError.tlsFailed("relay closed"))
        await connectTask.value

        XCTAssertEqual(manager.state, .error(.tlsHandshakeFailed))
        XCTAssertNotNil(manager.reconnectCountdown)
        XCTAssertNotEqual(manager.reconnectCountdown, 60)
        await manager.disconnect()
    }

    @MainActor
    func testWaitingForHomePathBucketChangeRedrivesAndConnects() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plViaSpl
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)
        var connectCountsAtDisconnect: [Int] = []
        transport.onDisconnectInvoked = {
            connectCountsAtDisconnect.append(transport.connectCallCount)
        }

        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        let didApplyBaseline = await Self.waitUntil {
            manager.currentPathStatus == .satisfiedWiFi
        }
        XCTAssertTrue(didApplyBaseline)
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        source.trigger(.satisfiedCellular)
        let didDisconnectFirst = await Self.waitUntil {
            transport.disconnectCallCount >= 1 && connectCountsAtDisconnect.first == 1
        }
        XCTAssertTrue(didDisconnectFirst)
        let didStartFreshConnect = await Self.waitUntil {
            transport.connectCallCount == 2
        }
        XCTAssertTrue(didStartFreshConnect)

        transport.completeSuspendedConnect(port: 5151)
        await firstConnectTask.value
        let didConnect = await Self.waitUntil {
            manager.state == .connected(localPort: 5151, via: .remote)
        }

        XCTAssertTrue(didConnect)
        XCTAssertEqual(manager.state, .connected(localPort: 5151, via: .remote))
        manager.stopNetworkMonitoring()
        await manager.disconnect()
    }

    @MainActor
    func testWaitingForHomeReturnToSatisfiedPathRedrives() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)
        var connectCountsAtDisconnect: [Int] = []
        transport.onDisconnectInvoked = {
            connectCountsAtDisconnect.append(transport.connectCallCount)
        }

        manager.startNetworkMonitoring()
        source.trigger(.unsatisfiedWiFi)
        let didApplyUnsatisfiedBaseline = await Self.waitUntil {
            manager.currentPathStatus == .unsatisfiedWiFi
        }
        XCTAssertTrue(didApplyUnsatisfiedBaseline)
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        source.trigger(.satisfiedWiFi)
        let didDisconnectFirst = await Self.waitUntil {
            transport.disconnectCallCount >= 1 && connectCountsAtDisconnect.first == 1
        }
        XCTAssertTrue(didDisconnectFirst)
        let didStartFreshConnect = await Self.waitUntil {
            transport.connectCallCount == 2
        }
        XCTAssertTrue(didStartFreshConnect)

        transport.completeSuspendedConnect(port: 5252)
        await firstConnectTask.value
        let didConnect = await Self.waitUntil {
            manager.state == .connected(localPort: 5252, via: .remote)
        }

        XCTAssertTrue(didConnect)
        XCTAssertEqual(manager.state, .connected(localPort: 5252, via: .remote))
        manager.stopNetworkMonitoring()
        await manager.disconnect()
    }

    @MainActor
    func testWaitingForHomeForegroundRedrivesAndConnects() async {
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(transport: transport)
        var connectCountsAtDisconnect: [Int] = []
        transport.onDisconnectInvoked = {
            connectCountsAtDisconnect.append(transport.connectCallCount)
        }
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        let redriveTask = Task { @MainActor in
            await manager.redriveFromWaitingForHome(reason: .foreground)
        }
        let didDisconnectFirst = await Self.waitUntil {
            transport.disconnectCallCount >= 1 && connectCountsAtDisconnect.first == 1
        }
        XCTAssertTrue(didDisconnectFirst)
        let didStartFreshConnect = await Self.waitUntil {
            transport.connectCallCount == 2
        }
        XCTAssertTrue(didStartFreshConnect)

        transport.completeSuspendedConnect(port: 5353)
        await redriveTask.value
        await firstConnectTask.value

        XCTAssertEqual(manager.state, .connected(localPort: 5353, via: .remote))
        await manager.disconnect()
    }

    @MainActor
    func testWaitingForHomeSameSatisfiedBucketPathDoesNotRedrive() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)

        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        let didApplyBaseline = await Self.waitUntil {
            manager.currentPathStatus == .satisfiedWiFi
        }
        XCTAssertTrue(didApplyBaseline)
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        source.trigger(NetworkPathStatus(
            isSatisfied: true,
            isWiFi: true,
            isCellular: false,
            isExpensive: true,
            isConstrained: true
        ))
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(transport.disconnectCallCount, 0)
        XCTAssertEqual(manager.state, .waitingForHome)
        manager.stopNetworkMonitoring()
        await manager.disconnect()
        await firstConnectTask.value
    }

    @MainActor
    func testConcurrentWaitingRedrivesStartAtMostOneFreshConnect() async {
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(transport: transport)
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        transport.emitAwaitingBrokerBeforeResult = false
        transport.suspendAfterAwaitingBroker = false
        transport.connectDelay = .milliseconds(120)
        transport.nextResult = .success(5454)

        let firstRedriveTask = Task { @MainActor in
            await manager.redriveFromWaitingForHome(reason: .foreground)
        }
        let secondRedriveTask = Task { @MainActor in
            await manager.redriveFromWaitingForHome(reason: .foreground)
        }

        await firstRedriveTask.value
        await secondRedriveTask.value
        await firstConnectTask.value

        XCTAssertLessThanOrEqual(transport.connectCallCount, 2)
        XCTAssertEqual(manager.state, .connected(localPort: 5454, via: .remote))
        await manager.disconnect()
    }

    @MainActor
    func testWaitingRedriveRearmsWaitingTimeoutWhenFreshAttemptAwaitsBroker() async {
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(
            transport: transport,
            waitingDeadline: .milliseconds(100)
        )
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        let redriveTask = Task { @MainActor in
            await manager.redriveFromWaitingForHome(reason: .foreground)
        }
        let didStartFreshConnect = await Self.waitUntil {
            transport.connectCallCount == 2 && manager.state == .waitingForHome
        }
        XCTAssertTrue(didStartFreshConnect)
        let didScheduleRelaxedRedial = await Self.waitUntil({
            manager.state == .waitingForHome
                && manager.reconnectCountdown == 60
                && transport.disconnectCallCount >= 2
        }, timeout: .seconds(2))
        XCTAssertTrue(didScheduleRelaxedRedial)

        await redriveTask.value
        await firstConnectTask.value
        XCTAssertEqual(manager.reconnectCount, 0)
        await manager.disconnect()
    }

    @MainActor
    func testWaitingRedriveFastFailureSchedulesReconnect() async {
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(
            transport: transport,
            initialRetryDelay: 1
        )
        var connectCountsAtDisconnect: [Int] = []
        transport.onDisconnectInvoked = {
            connectCountsAtDisconnect.append(transport.connectCallCount)
        }
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        let redriveTask = Task { @MainActor in
            await manager.redriveFromWaitingForHome(reason: .foreground)
        }
        let didStartFreshConnect = await Self.waitUntil {
            transport.connectCallCount == 2
        }
        XCTAssertTrue(didStartFreshConnect)

        transport.failSuspendedConnect(error: TunnelError.unreachable)
        await redriveTask.value
        await firstConnectTask.value

        XCTAssertEqual(connectCountsAtDisconnect.first, 1)
        XCTAssertEqual(manager.state, .error(.unreachable))
        XCTAssertNotNil(manager.reconnectCountdown)
        await manager.disconnect()
    }

    @MainActor
    func testWaitingRedriveDoesNotIncrementReconnectBuckets() async {
        let transport = MockCFTunnelTransport()
        transport.emitAwaitingBrokerBeforeResult = true
        transport.suspendAfterAwaitingBroker = true
        let manager = makeManager(transport: transport)
        let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

        let redriveTask = Task { @MainActor in
            await manager.redriveFromWaitingForHome(reason: .foreground)
        }
        let didStartFreshConnect = await Self.waitUntil {
            transport.connectCallCount == 2
        }
        XCTAssertTrue(didStartFreshConnect)

        transport.completeSuspendedConnect(port: 5555)
        await redriveTask.value
        await firstConnectTask.value

        XCTAssertEqual(manager.state, .connected(localPort: 5555, via: .remote))
        Self.assertReconnectBuckets(manager, expected: [:])
        await manager.disconnect()
    }

    @MainActor
    func testWaitingRedriveLogsTriggerDiagnostic() async {
        do {
            let transport = MockCFTunnelTransport()
            transport.emitAwaitingBrokerBeforeResult = true
            transport.suspendAfterAwaitingBroker = true
            let diagnosticLog = DiagnosticLog()
            let manager = makeManager(transport: transport, diagnosticLog: diagnosticLog)
            let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

            let redriveTask = Task { @MainActor in
                await manager.redriveFromWaitingForHome(reason: .foreground)
            }
            let didStartFreshConnect = await Self.waitUntil {
                transport.connectCallCount == 2
            }
            XCTAssertTrue(didStartFreshConnect)
            transport.completeSuspendedConnect(port: 5656)
            await redriveTask.value
            await firstConnectTask.value

            XCTAssertTrue(diagnosticLog.events.contains {
                $0.category == .tunnel && $0.message == "re-dialing" && $0.detail == "foreground"
            })
            await manager.disconnect()
        }

        do {
            let source = MockPathSource()
            let pathMonitor = PathMonitor(source: source)
            let transport = MockCFTunnelTransport()
            transport.emitAwaitingBrokerBeforeResult = true
            transport.suspendAfterAwaitingBroker = true
            let diagnosticLog = DiagnosticLog()
            let manager = makeManager(
                transport: transport,
                pathMonitor: pathMonitor,
                diagnosticLog: diagnosticLog
            )

            manager.startNetworkMonitoring()
            source.trigger(.satisfiedWiFi)
            let didApplyBaseline = await Self.waitUntil {
                manager.currentPathStatus == .satisfiedWiFi
            }
            XCTAssertTrue(didApplyBaseline)
            let firstConnectTask = await Self.startAwaitingBrokerConnect(manager: manager, transport: transport)

            source.trigger(.satisfiedCellular)
            let didStartFreshConnect = await Self.waitUntil {
                transport.connectCallCount == 2
            }
            XCTAssertTrue(didStartFreshConnect)
            transport.completeSuspendedConnect(port: 5757)
            await firstConnectTask.value
            let didConnect = await Self.waitUntil {
                manager.state == .connected(localPort: 5757, via: .remote)
            }
            XCTAssertTrue(didConnect)

            XCTAssertTrue(diagnosticLog.events.contains {
                $0.category == .tunnel && $0.message == "re-dialing" && $0.detail == "network changed"
            })
            manager.stopNetworkMonitoring()
            await manager.disconnect()
        }
    }

    @MainActor
    func testSuccessfulConnectLogsSinglePrepareCandidatesCompletion() async {
        let transport = MockCFTunnelTransport()
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(transport: transport, diagnosticLog: diagnosticLog)

        await manager.connect()
        await Self.settle()

        let prepareDoneEvents = diagnosticLog.events.filter {
            $0.category == .tunnel && $0.message.hasPrefix("stage: prepareCandidates done")
        }
        let raceStartedEvents = diagnosticLog.events.filter {
            $0.category == .tunnel && $0.message == "stage: raceCandidates started"
        }
        let raceDoneEvents = diagnosticLog.events.filter {
            $0.category == .tunnel && $0.message.hasPrefix("stage: raceCandidates done")
        }
        XCTAssertEqual(prepareDoneEvents.count, 1)
        XCTAssertFalse(raceStartedEvents.isEmpty)
        XCTAssertFalse(raceDoneEvents.isEmpty)
    }

    @MainActor
    func testConnectingWatchdogLogsTimeoutWarningDiagnostic() async {
        let transport = MockCFTunnelTransport()
        transport.suspendConnectUntilDisconnect = true
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(
            transport: transport,
            connectDeadline: .milliseconds(200),
            diagnosticLog: diagnosticLog
        )

        let connectTask = Task { @MainActor in
            await manager.connect()
        }
        let didTimeout = await Self.waitUntil {
            if case .error(.unreachable) = manager.state {
                return true
            }
            return false
        }
        guard didTimeout else {
            connectTask.cancel()
            await manager.disconnect()
            XCTFail("watchdog did not time out")
            return
        }
        await connectTask.value
        await Self.settle()

        let timeoutEvents = diagnosticLog.events.filter {
            $0.category == .tunnel && $0.severity == .warning && $0.message == "connection timed out"
        }
        XCTAssertEqual(timeoutEvents.count, 1)
        XCTAssertNil(timeoutEvents.first?.detail)
        await manager.disconnect()
    }

    @MainActor
    func testPathInterfaceFlipWhileConnectedForcesReconnect() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)

        await manager.connect()
        XCTAssertEqual(transport.connectCallCount, 1)

        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        let didApplyWiFiBaseline = await Self.waitUntil {
            manager.currentPathStatus == .satisfiedWiFi
        }

        XCTAssertTrue(didApplyWiFiBaseline)
        XCTAssertEqual(transport.disconnectCallCount, 0)
        XCTAssertEqual(transport.connectCallCount, 1)

        source.trigger(NetworkPathStatus(
            isSatisfied: true,
            isWiFi: false,
            isCellular: true,
            isExpensive: true,
            isConstrained: false
        ))
        let didForceReconnect = await Self.waitUntil {
            transport.disconnectCallCount == 1 && manager.reconnectCountdown != nil
        }

        XCTAssertTrue(didForceReconnect)
        XCTAssertEqual(transport.disconnectCallCount, 1)
        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(manager.isNetworkSatisfied, true)
        XCTAssertEqual(manager.currentInterfaceIsWiFi, false)
        XCTAssertEqual(manager.currentPathStatus?.isCellular, true)
        XCTAssertEqual(manager.currentPathStatus?.isExpensive, true)
        XCTAssertNotNil(manager.reconnectCountdown)

        source.trigger(NetworkPathStatus(
            isSatisfied: true,
            isWiFi: false,
            isCellular: true,
            isExpensive: false,
            isConstrained: false
        ))
        try? await Task.sleep(for: .milliseconds(80))
        await Self.settle()
        XCTAssertEqual(transport.disconnectCallCount, 1)

        await manager.retryNow()
        XCTAssertEqual(transport.connectCallCount, 2)
        manager.stopNetworkMonitoring()
        await manager.disconnect()
    }

    @MainActor
    func testSameBucketPathChangeWhileConnectedRecordsFactsWithoutFreshRace() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)

        await manager.connect()
        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        // Clear PathMonitor's 200ms debounce so the baseline bucket is established.
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        source.trigger(NetworkPathStatus(
            isSatisfied: true,
            isWiFi: true,
            isCellular: false,
            isExpensive: true,
            isConstrained: true
        ))
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertEqual(transport.disconnectCallCount, 0)
        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(manager.isNetworkSatisfied, true)
        XCTAssertEqual(manager.currentInterfaceIsWiFi, true)
        XCTAssertEqual(manager.currentPathStatus?.isExpensive, true)
        XCTAssertNil(manager.reconnectCountdown)
        manager.stopNetworkMonitoring()
        await manager.disconnect()
    }

    @MainActor
    func testSatisfiedPathSchedulesReconnectFromRetryableError() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)
        manager.state = .error(.unreachable)

        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertNotNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.connectCallCount, 0)
    }

    @MainActor
    func testSatisfiedPathSchedulesReconnectFromDisconnected() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)

        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertNotNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.connectCallCount, 0)
    }

    @MainActor
    func testUnsatisfiedPathDoesNotScheduleReconnect() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor)
        manager.state = .error(.unreachable)

        manager.startNetworkMonitoring()
        source.trigger(.unsatisfiedCellular)
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.connectCallCount, 0)
        XCTAssertEqual(manager.isNetworkSatisfied, false)
    }

    @MainActor
    func testProbeConnectionMarksNotAliveOnNon2xx() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/network/api/status")
            XCTAssertEqual(request.url?.port, 8080)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("not ready".utf8)
            )
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, probeSession: session)
        manager.forceConnected(port: 8080, via: .lan)

        let result = await manager.probeConnection()

        XCTAssertEqual(result?.alive, false)
        XCTAssertEqual(manager.lastProbeAlive, false)
        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 1)
    }

    @MainActor
    func testProbeConnectionMarksAliveOn2xx() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/network/api/status")
            XCTAssertEqual(request.url?.port, 8080)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, probeSession: session)
        manager.forceConnected(port: 8080, via: .lan)

        let result = await manager.probeConnection()

        XCTAssertEqual(result?.alive, true)
        XCTAssertEqual(manager.lastProbeAlive, true)
        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 1)
    }

    @MainActor
    func testProbeConnectionMarksNotReachableOnTransportFailure() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, probeSession: session)
        manager.forceConnected(port: 8080, via: .lan)

        let result = await manager.probeConnection()

        XCTAssertEqual(result?.alive, false)
        XCTAssertEqual(manager.lastProbeAlive, false)
        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 1)
    }

    @MainActor
    func testStandingLineStaysConnectedAfterSingleFailedProbe() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("not ready".utf8)
            )
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = makeManager(transport: transport, probeSession: session)
        manager.forceConnected(port: 8080, via: .lan)

        let first = await manager.probeConnection()

        XCTAssertEqual(first?.alive, false)
        XCTAssertEqual(manager.lastProbeAlive, false)
    }

    @MainActor
    func testLivenessProbeReconnectsAfterSustainedFailuresAndStops() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = makeManager(
            transport: transport,
            probeSession: session,
            probeInterval: .milliseconds(20),
            probeFailureThreshold: 2
        )

        await manager.connect()
        let didForceReconnect = await Self.waitUntil({
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }, timeout: .seconds(2))

        XCTAssertTrue(didForceReconnect)
        let requestCount = TunnelProbeURLProtocol.capturedRequests.count
        XCTAssertGreaterThanOrEqual(requestCount, 2)
        try? await Task.sleep(for: .milliseconds(140))
        await Self.settle()
        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, requestCount)
        await manager.disconnect()
    }

    @MainActor
    func testLivenessProbeDoesNotEscalateWhenInboundAdvancesDuringFailedProbes() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        transport.inboundActivitySnapshots = Array(0...100)
        let manager = makeManager(
            transport: transport,
            probeSession: session,
            probeInterval: .milliseconds(20),
            probeFailureThreshold: 2
        )

        await manager.connect()
        let didRunRepeatedFailedProbes = await Self.waitUntil({
            TunnelProbeURLProtocol.capturedRequests.count >= 3
        }, timeout: .seconds(2))

        XCTAssertTrue(didRunRepeatedFailedProbes)
        XCTAssertEqual(manager.state, .connected(localPort: 54321, via: .remote))
        XCTAssertNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.disconnectCallCount, 0)
        await manager.disconnect()
    }

    @MainActor
    func testLivenessProbeEscalatesActiveTransfersOnFirstFailureWithoutInboundDelta() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        transport.inboundActivitySnapshotValue = 42
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(
            transport: transport,
            probeSession: session,
            probeInterval: .milliseconds(20),
            probeFailureThreshold: 99,
            activeLocalTransferCountProvider: { 1 },
            diagnosticLog: diagnosticLog
        )

        await manager.connect()
        let didForceReconnect = await Self.waitUntil({
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }, timeout: .seconds(2))

        XCTAssertTrue(didForceReconnect)
        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 1)
        let escalation = try XCTUnwrap(diagnosticLog.events.last {
            $0.category == .tunnel && $0.message == "probe not reachable during active uploads"
        })
        XCTAssertEqual(escalation.severity, .warning)
        XCTAssertTrue((escalation.detail ?? "").contains("activeUploads=1"))
        XCTAssertTrue((escalation.detail ?? "").contains("port=54321"))
        XCTAssertTrue((escalation.detail ?? "").contains("epoch=1"))
        let reconnect = try XCTUnwrap(diagnosticLog.events.last {
            $0.category == .tunnel && $0.message == "forcing reconnect"
        })
        XCTAssertTrue((reconnect.detail ?? "").contains("probe failed"))
        await manager.disconnect()
    }

    @MainActor
    func testLivenessProbeActiveTransfersStillYieldToInboundAdvance() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        transport.inboundActivitySnapshots = Array(0...100)
        let manager = makeManager(
            transport: transport,
            probeSession: session,
            probeInterval: .milliseconds(20),
            probeFailureThreshold: 1,
            activeLocalTransferCountProvider: { 1 }
        )

        await manager.connect()
        let didRunRepeatedFailedProbes = await Self.waitUntil({
            TunnelProbeURLProtocol.capturedRequests.count >= 3
        }, timeout: .seconds(2))

        XCTAssertTrue(didRunRepeatedFailedProbes)
        XCTAssertEqual(manager.state, .connected(localPort: 54321, via: .remote))
        XCTAssertNil(manager.reconnectCountdown)
        XCTAssertEqual(transport.disconnectCallCount, 0)
        await manager.disconnect()
    }

    @MainActor
    func testLivenessProbeEscalatesBusyButStuckWithoutInboundDelta() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        transport.inboundActivitySnapshotValue = 42
        let manager = makeManager(
            transport: transport,
            probeSession: session,
            probeInterval: .milliseconds(20),
            probeFailureThreshold: 2
        )

        await manager.connect()
        let didForceReconnect = await Self.waitUntil({
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }, timeout: .seconds(2))

        XCTAssertTrue(didForceReconnect)
        await manager.disconnect()
    }

    @MainActor
    func testLivenessProbeEscalatesIdleUnresponsiveWithoutInboundDelta() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = makeManager(
            transport: transport,
            probeSession: session,
            probeInterval: .milliseconds(20),
            probeFailureThreshold: 1
        )

        await manager.connect()
        let didForceReconnect = await Self.waitUntil({
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }, timeout: .seconds(2))

        XCTAssertTrue(didForceReconnect)
        await manager.disconnect()
    }

    @MainActor
    func testConvergingDeathPathSignalsProduceSingleReconnectAttempt() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(
            transport: transport,
            pathMonitor: pathMonitor,
            probeSession: session,
            probeInterval: .milliseconds(40),
            probeFailureThreshold: 1
        )

        await manager.connect()
        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        await Self.settle()

        let probeForcedReconnect = await Self.waitUntil({
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }, timeout: .seconds(2))
        XCTAssertTrue(probeForcedReconnect)

        transport.simulateDisconnect(error: TunnelError.muxTeardown)
        source.trigger(NetworkPathStatus(
            isSatisfied: true,
            isWiFi: false,
            isCellular: true,
            isExpensive: false,
            isConstrained: false
        ))
        await Self.settle()
        XCTAssertEqual(transport.disconnectCallCount, 1)
        XCTAssertEqual(transport.connectCallCount, 1)

        TunnelProbeURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        await manager.retryNow()
        XCTAssertEqual(transport.connectCallCount, 2)
        try? await Task.sleep(for: .milliseconds(120))
        await Self.settle()
        XCTAssertEqual(transport.connectCallCount, 2)
        manager.stopNetworkMonitoring()
        await manager.disconnect()
    }

    @MainActor
    func testDeliberateDisconnectStopsProbeAndIgnoresUnsatisfiedPathChange() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let manager = makeManager(
            transport: transport,
            pathMonitor: pathMonitor,
            probeSession: session,
            probeInterval: .milliseconds(40),
            probeFailureThreshold: 1
        )

        await manager.connect()
        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        await Self.settle()

        await manager.disconnect()
        let requestCount = TunnelProbeURLProtocol.capturedRequests.count
        source.trigger(.unsatisfiedCellular)
        try? await Task.sleep(for: .milliseconds(140))
        await Self.settle()

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, requestCount)
        XCTAssertNil(manager.reconnectCountdown)
        manager.stopNetworkMonitoring()
    }

    @MainActor
    func testPostConnectForceReconnectIsNotOverwrittenByOldWatchdogDeadline() async {
        let transport = MockCFTunnelTransport()
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(
            transport: transport,
            connectDeadline: .milliseconds(80),
            diagnosticLog: diagnosticLog
        )

        await manager.connect()
        XCTAssertEqual(transport.connectCallCount, 1)

        // The watchdog should already be cancelled after connect success; this pins the defensive
        // forceReconnect cancellation so an old deadline cannot overwrite recovery with .unreachable.
        transport.simulateDisconnect(error: SessionError.directKeepaliveMissed)
        let didSchedule = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return manager.reconnectCountdown != nil
            }
            return false
        }
        XCTAssertTrue(didSchedule)

        try? await Task.sleep(for: .milliseconds(160))
        await Self.settle()
        XCTAssertEqual(manager.state, .error(.muxTeardown))
        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(transport.disconnectCallCount, 1)
        XCTAssertNotNil(manager.reconnectCountdown)
        let reconnectEvents = diagnosticLog.events.filter {
            $0.category == .tunnel && $0.message == "forcing reconnect"
        }
        XCTAssertEqual(reconnectEvents.last?.detail, "keepalive missed port=54321 epoch=1")
        await manager.disconnect()
    }

    @MainActor
    func testForcedReconnectStateSequenceLeavesConnectedAndReturns() async {
        let transport = MockCFTunnelTransport()
        transport.connectionMode = .plDirect
        transport.nextResult = .success(1111)
        let manager = makeManager(transport: transport)
        var states: [solstone_swift.TunnelState] = []

        await manager.connect()
        XCTAssertEqual(manager.state, .connected(localPort: 1111, via: .lan))
        states.append(manager.state)

        transport.connectDelay = .milliseconds(80)
        transport.nextResult = .success(2222)
        transport.simulateDisconnect(error: TunnelError.muxTeardown)
        let didReachError = await Self.waitUntil {
            if case .error(.muxTeardown) = manager.state {
                return true
            }
            return false
        }
        XCTAssertTrue(didReachError)
        states.append(manager.state)

        let retryTask = Task { @MainActor in
            await manager.retryNow()
        }
        let didStartConnecting = await Self.waitUntil {
            manager.state == .connecting
        }
        XCTAssertTrue(didStartConnecting)
        states.append(manager.state)
        await retryTask.value
        XCTAssertEqual(manager.state, .connected(localPort: 2222, via: .lan))
        states.append(manager.state)

        let firstConnected = states.firstIndex(of: .connected(localPort: 1111, via: .lan))
        let error = states.firstIndex(of: .error(.muxTeardown))
        let connecting = states.firstIndex(of: .connecting)
        let secondConnected = states.firstIndex(of: .connected(localPort: 2222, via: .lan))
        XCTAssertNotNil(firstConnected)
        XCTAssertNotNil(error)
        XCTAssertNotNil(connecting)
        XCTAssertNotNil(secondConnected)
        XCTAssertLessThan(firstConnected ?? 0, error ?? 0)
        XCTAssertLessThan(error ?? 0, connecting ?? 0)
        XCTAssertLessThan(connecting ?? 0, secondConnected ?? 0)
        await manager.disconnect()
    }

    @MainActor
    func testPathChangeDiagnosticsOnlyEmitForMeaningfulTransitions() async {
        let source = MockPathSource()
        let pathMonitor = PathMonitor(source: source)
        let transport = MockCFTunnelTransport()
        let diagnosticLog = DiagnosticLog()
        let manager = makeManager(transport: transport, pathMonitor: pathMonitor, diagnosticLog: diagnosticLog)

        manager.startNetworkMonitoring()
        source.trigger(.satisfiedWiFi)
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertEqual(Self.pathChangedEvents(in: diagnosticLog).count, 1)

        source.trigger(NetworkPathStatus(
            isSatisfied: true,
            isWiFi: true,
            isCellular: false,
            isExpensive: true,
            isConstrained: true
        ))
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertEqual(Self.pathChangedEvents(in: diagnosticLog).count, 1)

        source.trigger(NetworkPathStatus(
            isSatisfied: false,
            isWiFi: true,
            isCellular: false,
            isExpensive: true,
            isConstrained: true
        ))
        try? await Task.sleep(for: .milliseconds(260))
        await Self.settle()

        XCTAssertEqual(Self.pathChangedEvents(in: diagnosticLog).count, 2)
        manager.cancelReconnect()
        manager.stopNetworkMonitoring()
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

    @MainActor
    private static func assertReconnectBuckets(
        _ manager: TunnelManager,
        expected: [ReconnectReasonBucket: Int]
    ) {
        XCTAssertEqual(manager.reconnectCount, expected.values.reduce(0, +))
        for bucket in ReconnectReasonBucket.allCases {
            XCTAssertEqual(
                manager.reconnectReasonCounts[bucket] ?? 0,
                expected[bucket] ?? 0,
                "bucket \(bucket)"
            )
        }
    }

    @MainActor
    private static func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(1),
        interval: Duration = .milliseconds(20)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }

    @MainActor
    private static func startAwaitingBrokerConnect(
        manager: TunnelManager,
        transport: MockCFTunnelTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Task<Void, Never> {
        let connectTask = Task { @MainActor in
            await manager.connect()
        }
        let didEnterWait = await Self.waitUntil {
            manager.state == .waitingForHome && transport.connectCallCount == 1
        }
        XCTAssertTrue(didEnterWait, "tunnel did not enter waitingForHome", file: file, line: line)
        return connectTask
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("endpoints.json")
    }

    private static func probeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TunnelProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func tokenRefreshSession(responseData: Data = Data(), statusCode: Int = 200, error: URLError? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TunnelTokenRefreshURLProtocol.self]
        TunnelTokenRefreshURLProtocol.configure(responseData: responseData, statusCode: statusCode, error: error)
        return URLSession(configuration: configuration)
    }

    @MainActor
    private static func pathChangedEvents(in log: DiagnosticLog) -> [DiagnosticEvent] {
        log.events.filter { $0.category == .tunnel && $0.message == "path changed" }
    }

    private static func fixturePairing(
        localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "127.0.0.1", port: 8676, scope: "")],
        deviceToken: String? = nil
    ) -> StoredPairing {
        let deviceToken = deviceToken ?? Self.validFutureDeviceToken
        return StoredPairing(
            instanceID: "instance-123",
            homeLabel: "sol",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: "ca",
            relayEnrollment: .enrolled(deviceToken: deviceToken, expiresAt: nil),
            localEndpoints: localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }

    private static func localEndpoint(host: String, port: Int, scope: String) -> LocalEndpoint {
        LocalEndpoint(host: host, port: port, scope: scope)
    }

    private static let validFutureDeviceToken = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MjA4Mjc1ODQwMH0.sig"

    private static func tokenRefreshSuccessData(deviceToken: String = validFutureDeviceToken) -> Data {
        Data(#"{"device_token":"\#(deviceToken)","expires_at":"2036-01-01T00:00:00Z"}"#.utf8)
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

    private static func relayTokens(from candidates: [TransportEndpoint]) -> [String] {
        candidates.compactMap { endpoint in
            if case .relay(_, _, let deviceToken) = endpoint {
                return deviceToken
            }
            return nil
        }
    }
}

private final class TunnelProbeURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let capturedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var capturedRequests: [URLRequest] {
        get { self.capturedRequestsBox.withLock { $0 } }
        set { self.capturedRequestsBox.withLock { $0 = newValue } }
    }

    static func reset() {
        self.handler = nil
        self.capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequestsBox.withLock { $0.append(self.request) }
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
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

private final class TunnelTokenRefreshURLProtocol: URLProtocol, @unchecked Sendable {
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

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "relay.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = Self.state.withLock { state in
            state.requestURLs.append(self.request.url?.absoluteString ?? "")
            return state
        }
        if let error = current.error {
            self.client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: current.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: current.responseData)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NetworkPathStatus {
    static let satisfiedWiFi = NetworkPathStatus(
        isSatisfied: true,
        isWiFi: true,
        isCellular: false,
        isExpensive: false,
        isConstrained: false
    )

    static let unsatisfiedWiFi = NetworkPathStatus(
        isSatisfied: false,
        isWiFi: true,
        isCellular: false,
        isExpensive: false,
        isConstrained: false
    )

    static let satisfiedCellular = NetworkPathStatus(
        isSatisfied: true,
        isWiFi: false,
        isCellular: true,
        isExpensive: true,
        isConstrained: false
    )

    static let unsatisfiedCellular = NetworkPathStatus(
        isSatisfied: false,
        isWiFi: false,
        isCellular: true,
        isExpensive: true,
        isConstrained: false
    )
}
