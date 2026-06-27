// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
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
        deviceTokenRefresher: DeviceTokenRefresher = DeviceTokenRefresher(),
        initialRetryDelay: TimeInterval = 10,
        connectDeadline: Duration = .seconds(15),
        probeSession: URLSession = .shared,
        probeURLBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            URL(string: "http://127.0.0.1:\(localPort)/app/network/api/status")
        },
        probeInterval: Duration = .seconds(15),
        probeFailureThreshold: Int = 2,
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
            probeSession: probeSession,
            probeURLBuilder: probeURLBuilder,
            probeInterval: probeInterval,
            probeFailureThreshold: probeFailureThreshold,
            diagnosticLog: diagnosticLog
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
    func testPreDialRefreshUsesFreshRelayTokenAndSavesPairing() async {
        let oldToken = "bad-token"
        let newToken = Self.validFutureDeviceToken + "x"
        let original = Self.fixturePairing(localEndpoints: [], deviceToken: oldToken)
        let saved = OSAllocatedUnfairLock<StoredPairing?>(initialState: nil)
        let transport = MockCFTunnelTransport()
        let refresher = DeviceTokenRefresher(session: Self.tokenRefreshSession(responseData: Self.tokenRefreshSuccessData(deviceToken: newToken)))
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
            .failure(SessionError.tokenExpired),
            .success(8181),
        ]
        let refresher = DeviceTokenRefresher(session: Self.tokenRefreshSession(responseData: Self.tokenRefreshSuccessData(deviceToken: newToken)))
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
            .failure(SessionError.tokenExpired),
            .failure(SessionError.tokenExpired),
        ]
        let refresher = DeviceTokenRefresher(session: Self.tokenRefreshSession(responseData: Self.tokenRefreshSuccessData()))
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
    func testConnectionHealthRequiresSustainedProbeFailures() async throws {
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

        XCTAssertEqual(manager.connectionHealth, .healthy)

        let first = await manager.probeConnection()
        XCTAssertEqual(first?.alive, false)
        XCTAssertEqual(manager.lastProbeAlive, false)
        XCTAssertEqual(manager.connectionHealth, .healthy)

        let second = await manager.probeConnection()
        XCTAssertEqual(second?.alive, false)
        XCTAssertEqual(manager.connectionHealth, .degraded)

        TunnelProbeURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        let third = await manager.probeConnection()
        XCTAssertEqual(third?.alive, true)
        XCTAssertEqual(manager.lastProbeAlive, true)
        XCTAssertEqual(manager.connectionHealth, .healthy)
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
        XCTAssertEqual(manager.connectionHealth, .healthy)
        XCTAssertEqual(
            SourceVocabulary.standingSyncLine(health: manager.connectionHealth, syncing: false),
            "connected"
        )
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
        let manager = makeManager(
            transport: transport,
            connectDeadline: .milliseconds(80)
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
            XCTFail("TunnelProbeURLProtocol handler not set")
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

    static let unsatisfiedCellular = NetworkPathStatus(
        isSatisfied: false,
        isWiFi: false,
        isCellular: true,
        isExpensive: true,
        isConstrained: false
    )
}
