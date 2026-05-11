// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class TunnelManagerTests: XCTestCase {
    private lazy var mock = MockSSHTransport()
    @MainActor private lazy var manager = TunnelManager(transport: self.mock)

    private func settleStageCallbacks() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }

    @MainActor override func tearDown() async throws {
        await self.manager.disconnect()
    }

    @MainActor
    func testConnectLANSuccess() async {
        self.mock.probeLANResult = true
        self.mock.connectLocalPort = 8080

        await self.manager.connect()

        XCTAssertEqual(self.manager.state, .connected(localPort: 8080, via: .lan))
        XCTAssertEqual(self.mock.lastConnectEndpoint, .lan)
    }

    @MainActor
    func testConnectRemoteFallback() async {
        self.mock.probeLANResult = false
        self.mock.connectLocalPort = 9090

        await self.manager.connect()

        XCTAssertEqual(self.manager.state, .connected(localPort: 9090, via: .remote))
        XCTAssertEqual(self.mock.lastConnectEndpoint, .remote)
    }

    @MainActor
    func testConnectFailure() async {
        self.mock.connectError = .connectionTimeout

        await self.manager.connect()

        XCTAssertEqual(self.manager.state, .error(.connectionTimeout))
        XCTAssertTrue(self.mock.disconnectCalled)
    }

    @MainActor
    func testAlreadyConnectedGuard() async {
        self.mock.connectLocalPort = 8080
        await self.manager.connect()
        XCTAssertEqual(self.manager.state, .connected(localPort: 8080, via: .lan))

        self.mock.connectCallCount = 0
        await self.manager.connect()

        XCTAssertEqual(self.mock.connectCallCount, 0)
        XCTAssertEqual(self.manager.state, .connected(localPort: 8080, via: .lan))
    }

    @MainActor
    func testDisconnectCleanup() async {
        self.mock.connectLocalPort = 8080
        await self.manager.connect()

        await self.manager.disconnect()

        XCTAssertEqual(self.manager.state, .disconnected)
        XCTAssertTrue(self.mock.disconnectCalled)
    }

    @MainActor
    func testCancelConnectResetsState() async {
        self.mock.connectDelay = .seconds(1)
        self.mock.connectLocalPort = 8080

        let task = Task {
            await self.manager.connect()
        }
        await Task.yield()

        self.manager.cancelConnect()

        XCTAssertEqual(self.manager.state, .disconnected)

        task.cancel()
        await task.value

        self.mock.connectDelay = nil
        self.mock.connectCallCount = 0
        await self.manager.connect()
        XCTAssertGreaterThan(self.mock.connectCallCount, 0)
    }

    @MainActor
    func testHostKeyMismatch() async {
        self.mock.triggerHostKeyMismatch = true

        await self.manager.connect()
        await Task.yield()

        XCTAssertEqual(self.manager.state, .error(.hostKeyMismatch))
        XCTAssertTrue(self.manager.hasHostKeyMismatch)
    }

    @MainActor
    func testAcceptNewKeyReconnect() async {
        self.mock.triggerHostKeyMismatch = true
        await self.manager.connect()
        await Task.yield()

        XCTAssertTrue(self.manager.hasHostKeyMismatch)

        self.mock.triggerHostKeyMismatch = false
        self.mock.connectLocalPort = 8080
        self.mock.disconnectCalled = false

        await self.manager.acceptNewHostKey()

        XCTAssertFalse(self.manager.hasHostKeyMismatch)
        XCTAssertEqual(self.manager.state, .connected(localPort: 8080, via: .lan))
    }

    @MainActor
    func testAutoReconnectOnFailure() async {
        let manager = TunnelManager(transport: self.mock, initialRetryDelay: 0.1)
        self.mock.connectError = .connectionTimeout

        await manager.connect()

        XCTAssertEqual(manager.state, .error(.connectionTimeout))
        XCTAssertNotNil(manager.reconnectCountdown)

        await manager.disconnect()
    }

    @MainActor
    func testRetryNowCancelsBackoff() async {
        let manager = TunnelManager(transport: self.mock, initialRetryDelay: 10)
        self.mock.connectError = .connectionTimeout

        await manager.connect()
        XCTAssertNotNil(manager.reconnectCountdown)

        self.mock.connectError = nil
        self.mock.connectLocalPort = 8080
        let countBefore = self.mock.connectCallCount

        await manager.retryNow()

        XCTAssertNil(manager.reconnectCountdown)
        XCTAssertEqual(manager.state, .connected(localPort: 8080, via: .lan))
        XCTAssertGreaterThan(self.mock.connectCallCount, countBefore)

        await manager.disconnect()
    }

    @MainActor
    func testNoReconnectOnHostKeyMismatch() async {
        self.mock.triggerHostKeyMismatch = true

        await self.manager.connect()
        await Task.yield()

        XCTAssertEqual(self.manager.state, .error(.hostKeyMismatch))
        XCTAssertNil(self.manager.reconnectCountdown)
    }

    @MainActor
    func testNoReconnectOnAuthFailure() async {
        self.mock.connectError = .authenticationFailed

        await self.manager.connect()

        XCTAssertEqual(self.manager.state, .error(.authenticationFailed))
        XCTAssertNil(self.manager.reconnectCountdown)
    }

    @MainActor
    func testDisconnectCancelsReconnect() async {
        let manager = TunnelManager(transport: self.mock, initialRetryDelay: 10)
        self.mock.connectError = .connectionTimeout

        await manager.connect()
        XCTAssertNotNil(manager.reconnectCountdown)

        await manager.disconnect()
        XCTAssertNil(manager.reconnectCountdown)
        XCTAssertEqual(manager.state, .disconnected)
    }

    @MainActor
    func testBackoffResetsOnSuccess() async {
        let manager = TunnelManager(transport: self.mock, initialRetryDelay: 0.1)
        self.mock.connectError = .connectionTimeout

        await manager.connect()
        XCTAssertEqual(manager.state, .error(.connectionTimeout))

        self.mock.connectError = nil
        self.mock.connectLocalPort = 8080
        await manager.retryNow()
        XCTAssertEqual(manager.state, .connected(localPort: 8080, via: .lan))

        await manager.disconnect()
        self.mock.connectError = .connectionRefused
        self.mock.disconnectCalled = false

        await manager.connect()
        XCTAssertEqual(manager.state, .error(.connectionRefused))
        XCTAssertNotNil(manager.reconnectCountdown)

        await manager.disconnect()
    }

    @MainActor
    func testOnDisconnectTriggersReconnect() async {
        let manager = TunnelManager(transport: self.mock, initialRetryDelay: 10)
        self.mock.connectLocalPort = 8080

        await manager.connect()
        XCTAssertEqual(manager.state, .connected(localPort: 8080, via: .lan))

        self.mock.lastOnDisconnect?()
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(manager.state, .error(.tunnelClosed))
        XCTAssertNotNil(manager.reconnectCountdown)

        await manager.disconnect()
    }

    @MainActor
    func testHandleTunnelFailureTriggersReconnect() async {
        let manager = TunnelManager(transport: self.mock, initialRetryDelay: 10)
        self.mock.connectLocalPort = 8080

        await manager.connect()
        XCTAssertEqual(manager.state, .connected(localPort: 8080, via: .lan))

        await manager.handleTunnelFailure()

        XCTAssertEqual(manager.state, .error(.tunnelClosed))
        XCTAssertNotNil(manager.reconnectCountdown)
        XCTAssertTrue(self.mock.disconnectCalled)

        await manager.disconnect()
    }

    @MainActor
    func testHandleTunnelFailureIgnoredWhenNotConnected() async {
        await self.manager.handleTunnelFailure()
        XCTAssertEqual(self.manager.state, .disconnected)

        self.mock.connectError = .connectionTimeout
        await self.manager.connect()
        XCTAssertEqual(self.manager.state, .error(.connectionTimeout))
        self.mock.disconnectCalled = false

        await self.manager.handleTunnelFailure()
        XCTAssertEqual(self.manager.state, .error(.connectionTimeout))
        XCTAssertFalse(self.mock.disconnectCalled)
    }

    @MainActor
    func testConsecutiveWiFiFailuresTracking() async {
        self.mock.connectError = .connectionTimeout

        await self.manager.connect()
        XCTAssertEqual(self.manager.consecutiveWiFiFailures, 0)
        await self.manager.disconnect()

        self.manager.currentInterfaceIsWiFi = true
        self.mock.disconnectCalled = false
        await self.manager.connect()
        XCTAssertEqual(self.manager.consecutiveWiFiFailures, 1)
        await self.manager.disconnect()
        XCTAssertEqual(self.manager.consecutiveWiFiFailures, 0)

        self.manager.currentInterfaceIsWiFi = true
        self.mock.disconnectCalled = false
        await self.manager.connect()
        XCTAssertEqual(self.manager.consecutiveWiFiFailures, 1)

        self.mock.disconnectCalled = false
        await self.manager.retryNow()
        XCTAssertEqual(self.manager.consecutiveWiFiFailures, 2)

        self.mock.connectError = nil
        self.mock.connectLocalPort = 8080
        await self.manager.retryNow()
        XCTAssertEqual(self.manager.consecutiveWiFiFailures, 0)
    }

    @MainActor
    func testProbeConnection_MockReturnsConfiguredResult() async {
        self.mock.probeConnectionResult = true
        let alive = await self.mock.probeConnection()
        XCTAssertTrue(alive)
        XCTAssertEqual(self.mock.probeConnectionCallCount, 1)

        self.mock.probeConnectionResult = false
        let dead = await self.mock.probeConnection()
        XCTAssertFalse(dead)
        XCTAssertEqual(self.mock.probeConnectionCallCount, 2)
    }

    @MainActor
    func testShutdown_MockTracksCall() async {
        XCTAssertFalse(self.mock.shutdownCalled)
        await self.mock.shutdown()
        XCTAssertTrue(self.mock.shutdownCalled)
    }

    @MainActor
    func testConnectionHealthDerivedCorrectly() async {
        XCTAssertEqual(self.manager.connectionHealth, .unknown)

        await self.manager.connect()
        XCTAssertEqual(self.manager.connectionHealth, .healthy)

        self.manager.lastProbeAlive = true
        XCTAssertEqual(self.manager.connectionHealth, .healthy)

        self.manager.lastProbeAlive = false
        XCTAssertEqual(self.manager.connectionHealth, .degraded)

        await self.manager.disconnect()
        XCTAssertEqual(self.manager.connectionHealth, .unknown)
    }

    @MainActor
    func testReconnectCountLifecycle() async {
        XCTAssertEqual(self.manager.reconnectCount, 0)

        await self.manager.connect()
        XCTAssertEqual(self.manager.reconnectCount, 0)

        await self.manager.disconnect()
        self.mock.connectError = .connectionTimeout
        await self.manager.connect()
        XCTAssertEqual(self.manager.state, .error(.connectionTimeout))
        XCTAssertEqual(self.manager.reconnectCount, 0)

        self.mock.connectError = nil
        self.mock.connectLocalPort = 8080
        await self.manager.retryNow()
        XCTAssertEqual(self.manager.reconnectCount, 1)
        XCTAssertEqual(self.manager.state, .connected(localPort: 8080, via: .lan))

        await self.manager.disconnect()
        XCTAssertEqual(self.manager.reconnectCount, 0)
    }

    @MainActor
    func testKeepaliveResultCallback() async {
        await self.manager.connect()
        XCTAssertNil(self.manager.lastProbeAlive)
        XCTAssertEqual(self.manager.consecutiveKeepaliveFailures, 0)

        self.mock.lastOnKeepaliveResult?(true, 0)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(self.manager.lastProbeAlive, true)
        XCTAssertEqual(self.manager.consecutiveKeepaliveFailures, 0)

        self.mock.lastOnKeepaliveResult?(false, 1)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(self.manager.lastProbeAlive, false)
        XCTAssertEqual(self.manager.consecutiveKeepaliveFailures, 1)
    }

    @MainActor
    func testProbeConnectionSurfacesResult() async {
        self.mock.probeConnectionResult = true
        await self.manager.connect()

        let result = await self.manager.probeConnection()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.alive, true)
        XCTAssertEqual(self.manager.lastProbeAlive, true)
        XCTAssertEqual(self.mock.probeConnectionCallCount, 1)
    }

    @MainActor
    func testProbeConnectionWhenDisconnectedReturnsNil() async {
        let result = await self.manager.probeConnection()
        XCTAssertNil(result)
        XCTAssertEqual(self.mock.probeConnectionCallCount, 0)
    }

    @MainActor
    func testConnectionStagesPopulatedOnSuccess() async {
        self.mock.probeLANResult = true
        self.mock.connectLocalPort = 8080
        self.mock.stageEventsToEmit = [
            .sshConnecting, .sshConnected,
            .startingHubPhone,
            .hubPhoneReady(port: 51234),
            .portForwarding,
        ]

        await self.manager.connect()
        await self.settleStageCallbacks()

        XCTAssertEqual(self.manager.state, .connected(localPort: 8080, via: .lan))
        XCTAssertEqual(self.manager.connectionStages.count, 5)
        XCTAssertEqual(self.manager.connectionStages[0].kind, .lanProbe)
        XCTAssertEqual(self.manager.connectionStages[0].status, .done)
        XCTAssertEqual(self.manager.connectionStages[4].kind, .connected)
        XCTAssertEqual(self.manager.connectionStages[4].status, .done)
    }

    @MainActor
    func testConnectionStagesShowLANFailure() async {
        self.mock.probeLANResult = false
        self.mock.connectLocalPort = 9090
        self.mock.stageEventsToEmit = [
            .sshConnecting, .sshConnected,
            .startingHubPhone,
            .hubPhoneReady(port: 51234),
            .portForwarding,
        ]

        await self.manager.connect()
        await self.settleStageCallbacks()

        XCTAssertEqual(self.manager.state, .connected(localPort: 9090, via: .remote))
        XCTAssertEqual(self.manager.connectionStages[0].kind, .lanProbe)
        XCTAssertEqual(self.manager.connectionStages[0].status, .failed)
        XCTAssertEqual(self.manager.connectionStages[0].detail, "LAN unavailable")
    }

    @MainActor
    func testConnectionStagesResetOnRetry() async {
        self.mock.connectError = .connectionTimeout
        await self.manager.connect()
        await self.settleStageCallbacks()

        XCTAssertFalse(self.manager.connectionStages.isEmpty)

        self.mock.connectError = nil
        self.mock.connectLocalPort = 8080
        self.mock.stageEventsToEmit = [
            .sshConnecting, .sshConnected,
            .startingHubPhone,
            .hubPhoneReady(port: 51234),
            .portForwarding,
        ]
        await self.manager.retryNow()
        await self.settleStageCallbacks()

        XCTAssertEqual(self.manager.state, .connected(localPort: 8080, via: .lan))
        XCTAssertEqual(self.manager.connectionStages[0].kind, .lanProbe)
    }

    @MainActor
    func testConnectionStagesPreservedOnFailure() async {
        self.mock.connectError = .connectionTimeout
        self.mock.stageEventsToEmit = [.sshConnecting]

        await self.manager.connect()
        await self.settleStageCallbacks()

        XCTAssertEqual(self.manager.state, .error(.connectionTimeout))
        XCTAssertFalse(self.manager.connectionStages.isEmpty)
        XCTAssertEqual(self.manager.connectionStages[0].kind, .lanProbe)
    }

    @MainActor
    func testConnectionStagesClearedOnDisconnect() async {
        self.mock.connectLocalPort = 8080
        await self.manager.connect()
        await self.settleStageCallbacks()
        XCTAssertFalse(self.manager.connectionStages.isEmpty)

        await self.manager.disconnect()
        XCTAssertTrue(self.manager.connectionStages.isEmpty)
    }

    @MainActor
    func testExecOutputLoggedToDiagnostics() async {
        let diagLog = DiagnosticLog()
        let manager = TunnelManager(transport: self.mock, diagnosticLog: diagLog)
        self.mock.stageEventsToEmit = [
            .sshConnecting, .sshConnected,
            .startingHubPhone,
            .execOutput("starting hub-phone on port 0", isStdErr: false),
            .hubPhoneReady(port: 51234),
            .portForwarding,
        ]

        await manager.connect()
        await self.settleStageCallbacks()

        let execEvents = diagLog.events.filter { $0.message.hasPrefix("exec ") }
        XCTAssertFalse(execEvents.isEmpty, "expected exec output diagnostic events")
        XCTAssertEqual(execEvents.first?.severity, .info)
        XCTAssertEqual(execEvents.first?.detail, "starting hub-phone on port 0")

        await manager.disconnect()
    }

    @MainActor
    func testExecStderrLoggedAsWarning() async {
        let diagLog = DiagnosticLog()
        let manager = TunnelManager(transport: self.mock, diagnosticLog: diagLog)
        self.mock.stageEventsToEmit = [
            .sshConnecting, .sshConnected,
            .startingHubPhone,
            .execOutput("Traceback (most recent call last):", isStdErr: true),
            .hubPhoneReady(port: 51234),
            .portForwarding,
        ]

        await manager.connect()
        await self.settleStageCallbacks()

        let stderrEvents = diagLog.events.filter { $0.message == "exec stderr" }
        XCTAssertFalse(stderrEvents.isEmpty, "expected exec stderr diagnostic events")
        XCTAssertEqual(stderrEvents.first?.severity, .warning)

        await manager.disconnect()
    }

    @MainActor
    func testHubPhoneStartFailedSurfacesStderrInStageDetail() async {
        let diagLog = DiagnosticLog()
        let manager = TunnelManager(transport: self.mock, diagnosticLog: diagLog)
        self.mock.connectError = .hubPhoneStartFailed("ModuleNotFoundError: No module named 'hub_phone'")
        self.mock.stageEventsToEmit = [
            .sshConnecting, .sshConnected,
            .startingHubPhone,
        ]

        await manager.connect()
        await self.settleStageCallbacks()

        XCTAssertEqual(manager.state, .error(.hubPhoneStartFailed("ModuleNotFoundError: No module named 'hub_phone'")))

        let waitStage = manager.connectionStages.first(where: { $0.kind == .startHubPhone })
        XCTAssertNotNil(waitStage)
        XCTAssertEqual(waitStage?.status, .failed)
        XCTAssertEqual(waitStage?.detail, "ModuleNotFoundError: No module named 'hub_phone'")

        let errorEvents = diagLog.events.filter { $0.severity == .error }
        XCTAssertFalse(errorEvents.isEmpty, "expected error diagnostic event for hub-phone failure")

        await manager.disconnect()
    }

    @MainActor
    func testExecFailedLoggedAsDiagnosticError() async {
        let diagLog = DiagnosticLog()
        let manager = TunnelManager(transport: self.mock, diagnosticLog: diagLog)
        self.mock.stageEventsToEmit = [
            .sshConnecting, .sshConnected,
            .startingHubPhone,
            .execFailed(stderr: "Permission denied"),
            .hubPhoneReady(port: 51234),
            .portForwarding,
        ]

        await manager.connect()
        await self.settleStageCallbacks()

        let failEvents = diagLog.events.filter { $0.message == "hub-phone failed to start" && $0.severity == .error }
        XCTAssertFalse(failEvents.isEmpty, "expected hub-phone failure diagnostic event")
        XCTAssertEqual(failEvents.first?.detail, "Permission denied")

        await manager.disconnect()
    }
}
