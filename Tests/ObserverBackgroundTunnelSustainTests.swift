// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@testable import SPLTunnel
import AVFoundation
import Foundation
import os
import XCTest

@MainActor
final class ObserverBackgroundTunnelSustainTests: XCTestCase {
    func testIsBackgroundTunnelSustainedTruthTableAndActiveObserverKeepsTunnelConnectedOnBackgroundEntry() async throws {
        XCTAssertFalse(isBackgroundTunnelSustained(
            locationSustaining: false,
            finishSyncingActive: false,
            observerAudioSustaining: false
        ))
        XCTAssertTrue(isBackgroundTunnelSustained(
            locationSustaining: false,
            finishSyncingActive: false,
            observerAudioSustaining: true
        ))
        XCTAssertTrue(isBackgroundTunnelSustained(
            locationSustaining: true,
            finishSyncingActive: false,
            observerAudioSustaining: false
        ))
        XCTAssertTrue(isBackgroundTunnelSustained(
            locationSustaining: false,
            finishSyncingActive: true,
            observerAudioSustaining: false
        ))

        let rig = try await self.makeRig(paired: true, bootstrapInitially: true, connectInitially: true)
        rig.tunnelManager.receiveScenePhase(.active)

        let started = await rig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(started, .started)
        XCTAssertTrue(rig.observerManager.isSustainingBackground)

        rig.tunnelManager.receiveScenePhase(.background)
        let coordinator = try XCTUnwrap(rig.coordinator)
        coordinator.startBackgroundDrain()
        await coordinator.backgroundDrainTask?.value

        XCTAssertTrue(rig.tunnelManager.state.isConnected)
        XCTAssertEqual(rig.transport.disconnectCallCount, 0)
        XCTAssertTrue(rig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(rig.asserter.beginCount, 0)

        // While locked in the background, a 5-minute segment boundary delivers live over the open tunnel.
        rig.clock.advance(by: 300)
        try await Self.waitUntil("five-minute background segment delivered") {
            await rig.transferEngine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount == 1
        }
        XCTAssertTrue(rig.tunnelManager.state.isConnected)
        XCTAssertEqual(rig.transport.disconnectCallCount, 0)

        rig.tunnelManager.receiveScenePhase(.active)
        _ = await rig.observerManager.stopSession()
    }

    func testBackgroundStopSessionDrainsClosingAudioSegmentUnderBackgroundTaskBeforeDisconnect() async throws {
        let rig = try await self.makeRig(paired: true, bootstrapInitially: true, connectInitially: true)
        let coordinator = try XCTUnwrap(rig.coordinator)
        rig.tunnelManager.receiveScenePhase(.active)

        let started = await rig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(started, .started)

        rig.tunnelManager.receiveScenePhase(.background)
        coordinator.startBackgroundDrain()
        await coordinator.backgroundDrainTask?.value
        XCTAssertTrue(rig.tunnelManager.state.isConnected)
        XCTAssertEqual(rig.asserter.beginCount, 0)

        // Stop directly in .background with zero artificial pre-drain sleep and 250 ms mirror coalescing enabled.
        let stopped = await rig.observerManager.stopSession()
        XCTAssertEqual(stopped, .stopped)
        XCTAssertEqual(rig.observerManager.state, .idle)
        XCTAssertFalse(rig.observerManager.isSustainingBackground)

        let drainTask = try XCTUnwrap(coordinator.backgroundDrainTask)
        await drainTask.value

        XCTAssertEqual(rig.asserter.beginCount, 1)
        XCTAssertEqual(rig.asserter.endCount, 1)
        XCTAssertEqual(rig.deliveredCountAtDisconnect(), 1)
        XCTAssertEqual(rig.tunnelManager.state, .disconnected)
        XCTAssertFalse(rig.tunnelManager.isNetworkMonitoring)
    }

    func testBackgroundMicrophoneTakenDeadlineDrainsClosingAudioSegmentBeforeDisconnect() async throws {
        let rig = try await self.makeRig(paired: true, bootstrapInitially: true, connectInitially: true)
        let coordinator = try XCTUnwrap(rig.coordinator)
        rig.tunnelManager.receiveScenePhase(.active)

        let started = await rig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(started, .started)

        rig.tunnelManager.receiveScenePhase(.background)
        rig.recorder.emitInterruption(.began(.default))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(rig.recorder.pauseCallCount, 1)
        XCTAssertTrue(rig.observerManager.isSustainingBackground)

        rig.clock.advance(by: 60)
        try await Self.waitUntil("microphoneTaken deadline reached") {
            rig.observerManager.state == .microphoneTaken
        }
        XCTAssertFalse(rig.observerManager.isSustainingBackground)

        let drainTask = try XCTUnwrap(coordinator.backgroundDrainTask)
        await drainTask.value

        XCTAssertEqual(rig.asserter.beginCount, 1)
        XCTAssertEqual(rig.asserter.endCount, 1)
        XCTAssertEqual(rig.deliveredCountAtDisconnect(), 1)
        XCTAssertEqual(rig.tunnelManager.state, .disconnected)
    }

    func testBackgroundFiveMinuteRotationFailureHoldsSustainUntilFinalizedAndDrainsBeforeDisconnect() async throws {
        let rig = try await self.makeRig(paired: true, bootstrapInitially: true, connectInitially: true)
        let coordinator = try XCTUnwrap(rig.coordinator)
        rig.tunnelManager.receiveScenePhase(.active)

        let started = await rig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(started, .started)
        let firstChunkURL = try XCTUnwrap(rig.recorder.lastStartURL)
        let firstSegmentID = try XCTUnwrap(rig.recorder.lastStartSegmentID)

        rig.tunnelManager.receiveScenePhase(.background)

        var engineStateWhenSustainEnded: MobileSegmentEngine.EngineState?
        var activeDirExistsWhenSustainEnded: Bool?
        var visibleWorkWhenSustainEnded: Int?
        rig.observerManager.onSustainingBackgroundChanged = { isSustaining in
            if !isSustaining {
                engineStateWhenSustainEnded = rig.mobileSegmentEngine.state
                activeDirExistsWhenSustainEnded = FileManager.default.fileExists(
                    atPath: rig.mobileSegmentStore.segmentDirectoryURL(.active, segmentID: firstSegmentID).path
                )
                visibleWorkWhenSustainEnded = rig.mobileSegmentTransferHolder.pendingCount
                    + rig.mobileSegmentTransferHolder.inFlightCount
            }
            coordinator.handleObserverSustainingChanged(isSustaining)
        }

        rig.recorder.rotateError = PhoneAudioRotationHandoffFailure(
            priorChunk: ObserverRecordedChunk(url: firstChunkURL, duration: 300),
            stage: .engineRestart
        )
        try await Self.waitUntil("five-minute boundary timer armed") {
            rig.clock.pendingSleeperCount >= 1
        }
        rig.clock.advance(by: 300)

        try await Self.waitUntil("rotation failure settled") {
            !rig.observerManager.isSustainingBackground
        }

        XCTAssertEqual(engineStateWhenSustainEnded, .idle)
        XCTAssertEqual(activeDirExistsWhenSustainEnded, false)
        let deliveredSnapshot = await rig.transferEngine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount ?? 0
        XCTAssertGreaterThanOrEqual((visibleWorkWhenSustainEnded ?? 0) + deliveredSnapshot, 1)

        let drainTask = try XCTUnwrap(coordinator.backgroundDrainTask)
        await drainTask.value

        XCTAssertEqual(rig.asserter.beginCount, 1)
        XCTAssertEqual(rig.asserter.endCount, 1)
        XCTAssertEqual(rig.deliveredCountAtDisconnect(), 1)
        XCTAssertEqual(rig.tunnelManager.state, .disconnected)
    }

    func testBackgroundAlreadyInFlightUploadIsNotDisconnectedAtOutcomeThree() async {
        let asserter = SustainSpyBackgroundTaskAsserter()
        var inFlightCount = 1
        var disconnectCount = 0
        var driveCount = 0
        let coordinator = BackgroundDrainCoordinator(
            totals: { (failed: 0, pending: 0) },
            inFlight: { inFlightCount },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                driveCount += 1
                if driveCount >= 2 {
                    inFlightCount = 0
                }
            },
            disconnect: {
                XCTAssertEqual(inFlightCount, 0)
                disconnectCount += 1
            },
            asserter: asserter,
            clock: ImmediateWakeObserverClock(),
            settleInterval: .milliseconds(5)
        )

        await coordinator.run()

        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
        XCTAssertEqual(driveCount, 2)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testFinishSyncingCompletionAndExpirationKeepTunnelConnectedWhileObserverOrLocationSustains() async throws {
        let rig = try await self.makeRig(paired: true, bootstrapInitially: true, connectInitially: true)
        rig.tunnelManager.receiveScenePhase(.background)
        rig.tunnelManager.startNetworkMonitoring()

        var backlog = 2
        let scheduling = ManualFinishSyncingScheduling()
        let finishSyncing = FinishSyncingCoordinator(
            totals: { (failed: 0, pending: backlog) },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                if backlog > 0 {
                    backlog -= 1
                }
            },
            setPacingMode: { _ in },
            isConnected: { rig.tunnelManager.state.isConnected },
            isSiblingSustaining: {
                isBackgroundTunnelSustained(
                    locationSustaining: rig.locationManager.isSustainingBackground,
                    finishSyncingActive: false,
                    observerAudioSustaining: rig.observerManager.isSustainingBackground
                )
            },
            disconnect: {
                guard !isBackgroundTunnelSustained(
                    locationSustaining: rig.locationManager.isSustainingBackground,
                    finishSyncingActive: false,
                    observerAudioSustaining: rig.observerManager.isSustainingBackground
                ) else {
                    return
                }
                rig.tunnelManager.cancelConnect()
                rig.tunnelManager.cancelReconnect()
                rig.tunnelManager.stopNetworkMonitoring()
                await rig.tunnelManager.disconnect()
            },
            scheduling: scheduling,
            clock: ImmediateWakeObserverClock(),
            settleInterval: .milliseconds(5)
        )

        // 1. Complete and expire while phone-mic audio is sustaining.
        let started = await rig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(started, .started)
        XCTAssertTrue(rig.observerManager.isSustainingBackground)

        backlog = 1
        let completeHandle = ManualFinishSyncingTaskHandle()
        await finishSyncing.runTask(completeHandle)
        XCTAssertEqual(completeHandle.completedSuccess, true)
        XCTAssertTrue(rig.tunnelManager.state.isConnected)
        XCTAssertTrue(rig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(rig.transport.disconnectCallCount, 0)

        backlog = 3
        let expireHandle = ManualFinishSyncingTaskHandle(expireOnSetExpiration: true)
        await finishSyncing.runTask(expireHandle)
        XCTAssertEqual(expireHandle.completedSuccess, false)
        XCTAssertTrue(rig.tunnelManager.state.isConnected)
        XCTAssertTrue(rig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(rig.transport.disconnectCallCount, 0)

        rig.tunnelManager.receiveScenePhase(.active)
        _ = await rig.observerManager.stopSession()
        rig.tunnelManager.receiveScenePhase(.background)

        // 2. Complete and expire while Location Always is sustaining.
        rig.locationProvider.capability = .always(accuracy: .full)
        await rig.locationManager.start(tier: .balanced)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(rig.locationManager.isSustainingBackground)
        XCTAssertFalse(rig.observerManager.isSustainingBackground)

        backlog = 1
        let locationCompleteHandle = ManualFinishSyncingTaskHandle()
        await finishSyncing.runTask(locationCompleteHandle)
        XCTAssertEqual(locationCompleteHandle.completedSuccess, true)
        XCTAssertTrue(rig.tunnelManager.state.isConnected)
        XCTAssertTrue(rig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(rig.transport.disconnectCallCount, 0)

        backlog = 2
        let locationExpireHandle = ManualFinishSyncingTaskHandle(expireOnSetExpiration: true)
        await finishSyncing.runTask(locationExpireHandle)
        XCTAssertEqual(locationExpireHandle.completedSuccess, false)
        XCTAssertTrue(rig.tunnelManager.state.isConnected)
        XCTAssertTrue(rig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(rig.transport.disconnectCallCount, 0)

        await rig.locationManager.stop()
        XCTAssertFalse(rig.locationManager.isSustainingBackground)

        // 3. Control: when neither audio nor Location Always sustains, FinishSyncing disconnects.
        backlog = 1
        let unsustainedHandle = ManualFinishSyncingTaskHandle()
        await finishSyncing.runTask(unsustainedHandle)
        XCTAssertEqual(unsustainedHandle.completedSuccess, true)
        XCTAssertEqual(rig.tunnelManager.state, .disconnected)
        XCTAssertFalse(rig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(rig.transport.disconnectCallCount, 1)
    }

    func testBackgroundLivenessCadenceIsAtMostEighteenSecondsAndWaitingForHomeRedrivesWhenSustained() async throws {
        let defaultManager = TunnelManager(
            transport: MockCFTunnelTransport(),
            endpointCache: EndpointCache(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")),
            automaticallyReconnectOnCredentialReplacement: false
        )
        XCTAssertLessThanOrEqual(defaultManager.backgroundProbeInterval, .seconds(18))
        XCTAssertEqual(defaultManager.backgroundProbeInterval, .seconds(18))
        XCTAssertLessThanOrEqual(CFTunnelTransport.backgroundKeepaliveInterval, .seconds(18))
        XCTAssertEqual(CFTunnelTransport.backgroundKeepaliveInterval, .seconds(18))
        await defaultManager.disconnect()

        // Manual (.retryNow) redrive in .background when sustained vs unsustained.
        let manualPathSource = SustainMockPathSource()
        let manualTransport = MockCFTunnelTransport()
        manualTransport.emitAwaitingBrokerBeforeResult = true
        manualTransport.suspendAfterAwaitingBroker = true
        let manualSustaining = SustainingFlagBox()
        let manualManager = self.makeStandaloneTunnelManager(
            transport: manualTransport,
            pathSource: manualPathSource,
            isBackgroundSustained: { manualSustaining.value }
        )
        manualManager.receiveScenePhase(.active)
        let initialManualConnect = Task { @MainActor in
            await manualManager.connect()
        }
        try await Self.waitUntil("entered waitingForHome") {
            manualManager.state == .waitingForHome && manualTransport.connectCallCount == 1
        }
        manualManager.receiveScenePhase(.background)

        // Control: unsustained background retryNow() does not redrive waitingForHome.
        await manualManager.retryNow()
        XCTAssertEqual(manualTransport.connectCallCount, 1)
        XCTAssertEqual(manualManager.state, .waitingForHome)

        // Sustained background retryNow() redrives candidate racing and connects.
        manualSustaining.value = true
        manualTransport.emitAwaitingBrokerBeforeResult = false
        manualTransport.suspendAfterAwaitingBroker = false
        manualTransport.nextResult = .success(6123)
        await manualManager.retryNow()
        await initialManualConnect.value
        XCTAssertEqual(manualTransport.connectCallCount, 2)
        XCTAssertEqual(manualManager.state, .connected(localPort: 6123, via: .remote))
        await manualManager.disconnect()

        // Network-changed redrive in .background when sustained vs unsustained.
        let netPathSource = SustainMockPathSource()
        let netTransport = MockCFTunnelTransport()
        netTransport.emitAwaitingBrokerBeforeResult = true
        netTransport.suspendAfterAwaitingBroker = true
        let netSustaining = SustainingFlagBox()
        let netManager = self.makeStandaloneTunnelManager(
            transport: netTransport,
            pathSource: netPathSource,
            isBackgroundSustained: { netSustaining.value }
        )
        netManager.receiveScenePhase(.active)
        netManager.startNetworkMonitoring()
        netPathSource.trigger(Self.satisfiedWiFi)
        try? await Task.sleep(for: .milliseconds(260))

        let initialNetConnect = Task { @MainActor in
            await netManager.connect()
        }
        try await Self.waitUntil("net manager entered waitingForHome") {
            netManager.state == .waitingForHome && netTransport.connectCallCount == 1
        }
        netManager.receiveScenePhase(.background)

        let cellular = NetworkPathStatus(
            isSatisfied: true,
            isWiFi: false,
            isCellular: true,
            isExpensive: true,
            isConstrained: false
        )
        // Control: unsustained network change in .background does not redrive waitingForHome.
        netPathSource.trigger(cellular)
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(netTransport.connectCallCount, 1)
        XCTAssertEqual(netManager.state, .waitingForHome)

        // Sustained network change in .background redrives candidate racing and connects.
        netSustaining.value = true
        netTransport.emitAwaitingBrokerBeforeResult = false
        netTransport.suspendAfterAwaitingBroker = false
        netTransport.nextResult = .success(6124)
        netPathSource.trigger(Self.satisfiedWiFi)
        try await Self.waitUntil("sustained networkChanged redrive connected") {
            netTransport.connectCallCount == 2 && netManager.state == .connected(localPort: 6124, via: .remote)
        }
        await initialNetConnect.value
        netManager.stopNetworkMonitoring()
        await netManager.disconnect()
    }

    func testNonActiveObserverStartBootstrapsTransferAndConnectsFromDisconnectedRetryableErrorAndWaitingForHome() async throws {
        let ingestDescriptor = TransferEndpointDescriptor(
            destinationKind: .observerIngest,
            path: "/app/devices/ingest"
        )

        // 1. .inactive (Control Center overlay) from .disconnected via ObserverSessionControlling.
        let inactiveRig = try await self.makeRig(paired: true, bootstrapInitially: false, connectInitially: false)
        let inactiveCoordinator = try XCTUnwrap(inactiveRig.coordinator)
        inactiveRig.tunnelManager.receiveScenePhase(.inactive)
        inactiveRig.transport.nextResult = .success(7101)

        let inactiveStarted = await (inactiveRig.observerManager as any ObserverSessionControlling)
            .startCaptureSession(mode: .meeting)
        XCTAssertTrue(inactiveStarted)
        await inactiveCoordinator.sustainStartTask?.value

        XCTAssertEqual(inactiveRig.bootstrapCallCount, 1)
        XCTAssertTrue(inactiveRig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(inactiveRig.tunnelManager.state, .connected(localPort: 7101, via: .remote))
        try await Self.waitUntil("endpoint resolver wired on inactive start") {
            if case .available(let resolved) = await inactiveRig.endpointResolver.resolve(ingestDescriptor) {
                return resolved.port == 7101
            }
            return false
        }
        inactiveRig.tunnelManager.receiveScenePhase(.active)
        _ = await inactiveRig.observerManager.stopSession()

        // 2. .background from retryable .error(.unreachable).
        let errorRig = try await self.makeRig(paired: true, bootstrapInitially: false, connectInitially: false)
        let errorCoordinator = try XCTUnwrap(errorRig.coordinator)
        errorRig.tunnelManager.receiveScenePhase(.background)
        errorRig.tunnelManager.state = .error(.unreachable)
        errorRig.transport.nextResult = .success(7102)

        let errorStarted = await errorRig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(errorStarted, .started)
        await errorCoordinator.sustainStartTask?.value

        XCTAssertEqual(errorRig.bootstrapCallCount, 1)
        XCTAssertTrue(errorRig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(errorRig.tunnelManager.state, .connected(localPort: 7102, via: .remote))
        errorRig.tunnelManager.receiveScenePhase(.active)
        _ = await errorRig.observerManager.stopSession()

        // 3. .background from .waitingForHome redrives candidate racing and connects.
        let waitingRig = try await self.makeRig(paired: true, bootstrapInitially: false, connectInitially: false)
        let waitingCoordinator = try XCTUnwrap(waitingRig.coordinator)
        waitingRig.tunnelManager.receiveScenePhase(.active)
        waitingRig.transport.emitAwaitingBrokerBeforeResult = true
        waitingRig.transport.suspendAfterAwaitingBroker = true
        let initialWaitingConnect = Task { @MainActor in
            await waitingRig.tunnelManager.connect()
        }
        try await Self.waitUntil("waitingForHome armed") {
            waitingRig.tunnelManager.state == .waitingForHome && waitingRig.transport.connectCallCount == 1
        }
        waitingRig.tunnelManager.receiveScenePhase(.background)
        waitingRig.transport.emitAwaitingBrokerBeforeResult = false
        waitingRig.transport.suspendAfterAwaitingBroker = false
        waitingRig.transport.nextResult = .success(7103)

        let waitingStarted = await waitingRig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(waitingStarted, .started)
        await waitingCoordinator.sustainStartTask?.value
        await initialWaitingConnect.value

        XCTAssertEqual(waitingRig.bootstrapCallCount, 1)
        XCTAssertEqual(waitingRig.transport.connectCallCount, 2)
        XCTAssertEqual(waitingRig.tunnelManager.state, .connected(localPort: 7103, via: .remote))
        waitingRig.tunnelManager.receiveScenePhase(.active)
        _ = await waitingRig.observerManager.stopSession()

        // 4. Cold-launch no-scene .background path (hasReceivedScenePhase == false, fallback == .background):
        //    starts session via ObserverSessionControlling, connects tunnel, then stops in .background and delivers segment!
        let coldRig = try await self.makeRig(
            paired: true,
            bootstrapInitially: false,
            connectInitially: false,
            fallbackScenePhase: .background
        )
        let coldCoordinator = try XCTUnwrap(coldRig.coordinator)
        XCTAssertFalse(coldRig.tunnelManager.hasReceivedScenePhase)
        coldRig.transport.nextResult = .success(7104)

        let coldStarted = await (coldRig.observerManager as any ObserverSessionControlling)
            .startCaptureSession(mode: .meeting)
        XCTAssertTrue(coldStarted)
        await coldCoordinator.sustainStartTask?.value

        XCTAssertTrue(coldRig.tunnelManager.hasReceivedScenePhase)
        XCTAssertEqual(coldRig.tunnelManager.scenePhase, .background)
        XCTAssertEqual(coldRig.bootstrapCallCount, 1)
        XCTAssertEqual(coldRig.tunnelManager.state, .connected(localPort: 7104, via: .remote))

        let coldStopped = await (coldRig.observerManager as any ObserverSessionControlling).stopCaptureSession()
        XCTAssertTrue(coldStopped)
        let coldDrain = try XCTUnwrap(coldCoordinator.backgroundDrainTask)
        await coldDrain.value

        XCTAssertEqual(coldRig.asserter.beginCount, 1)
        XCTAssertEqual(coldRig.asserter.endCount, 1)
        XCTAssertEqual(coldRig.deliveredCountAtDisconnect(), 1)
        XCTAssertEqual(coldRig.tunnelManager.state, .disconnected)

        // 5. Unpaired does NOT connect or start network monitoring.
        let unpairedRig = try await self.makeRig(paired: false, bootstrapInitially: false, connectInitially: false)
        let unpairedCoordinator = try XCTUnwrap(unpairedRig.coordinator)
        unpairedRig.tunnelManager.receiveScenePhase(.background)
        let unpairedStarted = await unpairedRig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(unpairedStarted, .started)
        await unpairedCoordinator.sustainStartTask?.value
        XCTAssertEqual(unpairedRig.transport.connectCallCount, 0)
        XCTAssertFalse(unpairedRig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(unpairedRig.tunnelManager.state, .disconnected)
        unpairedRig.tunnelManager.receiveScenePhase(.active)
        _ = await unpairedRig.observerManager.stopSession()

        // 6. Non-retryable .error(.revoked) does NOT connect or start network monitoring.
        let revokedRig = try await self.makeRig(paired: true, bootstrapInitially: false, connectInitially: false)
        let revokedCoordinator = try XCTUnwrap(revokedRig.coordinator)
        revokedRig.tunnelManager.receiveScenePhase(.background)
        revokedRig.tunnelManager.state = .error(.revoked)
        let revokedStarted = await revokedRig.observerManager.startSession(mode: .meeting)
        XCTAssertEqual(revokedStarted, .started)
        await revokedCoordinator.sustainStartTask?.value
        XCTAssertEqual(revokedRig.transport.connectCallCount, 0)
        XCTAssertFalse(revokedRig.tunnelManager.isNetworkMonitoring)
        XCTAssertEqual(revokedRig.tunnelManager.state, .error(.revoked))
        revokedRig.tunnelManager.receiveScenePhase(.active)
        _ = await revokedRig.observerManager.stopSession()
    }
}

private extension ObserverBackgroundTunnelSustainTests {
    static let satisfiedWiFi = NetworkPathStatus(
        isSatisfied: true,
        isWiFi: true,
        isCellular: false,
        isExpensive: false,
        isConstrained: false
    )

    static func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(4),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let final = await condition()
        XCTAssertTrue(final, "Timed out waiting for \(description)")
    }

    final class SustainRig {
        let tempDirectory: URL
        let defaultsSuite: String
        let defaults: UserDefaults
        let clock: ImmediateWakeObserverClock
        let recorder: MockObserverRecorder
        let liveActivity: MockObserverLiveActivity
        let locationProvider: MockLocationProvider
        let mobileSegmentStore: MobileSegmentStore
        let mobileSegmentUploader: MobileSegmentUploader
        let mobileSegmentEngine: MobileSegmentEngine
        let mobileSegmentTransferHolder: MobileSegmentTransferHolder
        let locationManager: LocationManager
        let observerManager: ObserverManager
        let transferEngine: TransferEngine
        let transferMirror: TransferStatusMirror
        let transferTransport: TransferTransport
        let endpointResolver: LoopbackTransferEndpointResolver
        let transport: MockCFTunnelTransport
        let pathSource: SustainMockPathSource
        let tunnelManager: TunnelManager
        let asserter: SustainSpyBackgroundTaskAsserter
        var coordinator: ObserverBackgroundTunnelCoordinator?
        var bootstrapCallCount = 0
        let deliveredAtDisconnect = OSAllocatedUnfairLock(initialState: 0)

        init(
            tempDirectory: URL,
            defaultsSuite: String,
            defaults: UserDefaults,
            clock: ImmediateWakeObserverClock,
            recorder: MockObserverRecorder,
            liveActivity: MockObserverLiveActivity,
            locationProvider: MockLocationProvider,
            mobileSegmentStore: MobileSegmentStore,
            mobileSegmentUploader: MobileSegmentUploader,
            mobileSegmentEngine: MobileSegmentEngine,
            mobileSegmentTransferHolder: MobileSegmentTransferHolder,
            locationManager: LocationManager,
            observerManager: ObserverManager,
            transferEngine: TransferEngine,
            transferMirror: TransferStatusMirror,
            transferTransport: TransferTransport,
            endpointResolver: LoopbackTransferEndpointResolver,
            transport: MockCFTunnelTransport,
            pathSource: SustainMockPathSource,
            tunnelManager: TunnelManager,
            asserter: SustainSpyBackgroundTaskAsserter
        ) {
            self.tempDirectory = tempDirectory
            self.defaultsSuite = defaultsSuite
            self.defaults = defaults
            self.clock = clock
            self.recorder = recorder
            self.liveActivity = liveActivity
            self.locationProvider = locationProvider
            self.mobileSegmentStore = mobileSegmentStore
            self.mobileSegmentUploader = mobileSegmentUploader
            self.mobileSegmentEngine = mobileSegmentEngine
            self.mobileSegmentTransferHolder = mobileSegmentTransferHolder
            self.locationManager = locationManager
            self.observerManager = observerManager
            self.transferEngine = transferEngine
            self.transferMirror = transferMirror
            self.transferTransport = transferTransport
            self.endpointResolver = endpointResolver
            self.transport = transport
            self.pathSource = pathSource
            self.tunnelManager = tunnelManager
            self.asserter = asserter
        }

        func deliveredCountAtDisconnect() -> Int {
            self.deliveredAtDisconnect.withLock { $0 }
        }
    }

    func makeRig(
        paired: Bool,
        bootstrapInitially: Bool,
        connectInitially: Bool,
        fallbackScenePhase: TunnelScenePhase = .active
    ) async throws -> SustainRig {
        TransferURLProtocol.reset()
        TransferURLProtocol.handler = { request, body in
            (
                transferTestResponse(for: request, statusCode: 200),
                transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
            )
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverBackgroundTunnelSustainTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "ObserverBackgroundTunnelSustainTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let pairing = Self.fixturePairing()
        let pairingBox = OSAllocatedUnfairLock<StoredPairing?>(initialState: paired ? pairing : nil)
        let confirmation = JournalSendConfirmationStore.memory()
        let migration = DeviceMigrationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { pairingBox.withLock { $0 } },
            savePairing: { updated in pairingBox.withLock { $0 = updated } },
            deletePairing: { pairingBox.withLock { $0 = nil } }
        )
        if paired {
            try credentials.applyPairing(pairing)
            try confirmation.writeRecord(for: pairing)
        }

        let endpointResolver = LoopbackTransferEndpointResolver(
            credentials: credentials,
            confirmation: confirmation
        )
        let transferMirror = TransferStatusMirror()
        let transferTransport = TransferTransport(
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            admission: { endpoint in
                await endpointResolver.isCurrent(endpoint)
            },
            requestAdmission: { endpoint, start in
                await endpointResolver.startRequest(endpoint, start: start)
            }
        )
        let transferEngine = TransferEngine(
            spool: TransferSpool(rootURL: tempDirectory.appendingPathComponent("Transfers", isDirectory: true)),
            transport: transferTransport,
            endpointResolver: endpointResolver,
            statusMirror: transferMirror
        )

        let clock = ImmediateWakeObserverClock()
        let mobileSegmentStore = MobileSegmentStore(
            rootURL: tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        )
        let mobileSegmentUploader = MobileSegmentUploader(
            transferEngine: transferEngine,
            store: mobileSegmentStore,
            clock: clock
        )
        let mobileSegmentTransferHolder = MobileSegmentTransferHolder(
            transferEngine: transferEngine,
            mirror: transferMirror,
            uploader: mobileSegmentUploader
        )
        let mobileSegmentEngine = MobileSegmentEngine(
            uploader: mobileSegmentUploader,
            clock: clock
        )
        let locationProvider = MockLocationProvider()
        let locationManager = LocationManager(
            provider: locationProvider,
            mobileSegmentEngine: mobileSegmentEngine,
            clock: clock,
            defaults: defaults,
            ageGate: AgeSignalGate(isEnabled: false, store: AgeSignalStore(suiteName: suiteName))
        )
        let recorder = MockObserverRecorder()
        let liveActivity = MockObserverLiveActivity()
        let observerManager = ObserverManager(
            recorder: recorder,
            mobileSegmentEngine: mobileSegmentEngine,
            journalEvents: mobileSegmentUploader.journalEvents,
            clock: clock,
            liveActivity: liveActivity,
            defaults: defaults,
            ageGate: AgeSignalGate(isEnabled: false, store: AgeSignalStore(suiteName: suiteName))
        )

        let shareImportStore = ShareImportStore(
            cacheRootURL: tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        )
        let shareTransferHolder = ShareTransferHolder(
            transferEngine: transferEngine,
            mirror: transferMirror,
            store: shareImportStore
        )
        let watchHolder = WatchUploaderHolder(transferEngine: transferEngine, mirror: transferMirror)

        let transport = MockCFTunnelTransport()
        transport.nextResult = .success(7071)
        let pathSource = SustainMockPathSource()
        let tunnelManager = TunnelManager(
            transport: transport,
            endpointCache: EndpointCache(fileURL: tempDirectory.appendingPathComponent("endpoints.json")),
            pathMonitor: PathMonitor(source: pathSource),
            loadPairing: { pairingBox.withLock { $0 } },
            savePairing: { updated in pairingBox.withLock { $0 = updated } },
            deletePairing: { pairingBox.withLock { $0 = nil } },
            store: credentials,
            probeWatchdogPolicy: ProbeWatchdogPolicy(
                healthyInterval: .seconds(60),
                silentFailureLimit: 2,
                activeInboundFailureLimit: 6
            ),
            automaticallyReconnectOnCredentialReplacement: false,
            ageGate: AgeSignalGate(isEnabled: false, store: AgeSignalStore(suiteName: suiteName))
        )

        let asserter = SustainSpyBackgroundTaskAsserter()
        let rig = SustainRig(
            tempDirectory: tempDirectory,
            defaultsSuite: suiteName,
            defaults: defaults,
            clock: clock,
            recorder: recorder,
            liveActivity: liveActivity,
            locationProvider: locationProvider,
            mobileSegmentStore: mobileSegmentStore,
            mobileSegmentUploader: mobileSegmentUploader,
            mobileSegmentEngine: mobileSegmentEngine,
            mobileSegmentTransferHolder: mobileSegmentTransferHolder,
            locationManager: locationManager,
            observerManager: observerManager,
            transferEngine: transferEngine,
            transferMirror: transferMirror,
            transferTransport: transferTransport,
            endpointResolver: endpointResolver,
            transport: transport,
            pathSource: pathSource,
            tunnelManager: tunnelManager,
            asserter: asserter
        )

        let deliveredAtDisconnect = rig.deliveredAtDisconnect
        transport.onDisconnectAwaited = {
            let delivered = await transferEngine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount ?? 0
            deliveredAtDisconnect.withLock { $0 = delivered }
        }

        let coordinator = ObserverBackgroundTunnelCoordinator(
            tunnelManager: tunnelManager,
            transferEndpointResolver: endpointResolver,
            transferEngine: transferEngine,
            bootstrapTransferAction: { [weak rig, weak mobileSegmentUploader] in
                rig?.bootstrapCallCount += 1
                await transferEngine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.mobileSegment) { manifest, _ in
                    guard let segmentID = manifest.observerIngest?.segmentID else { return }
                    try await MainActor.run {
                        try mobileSegmentUploader?.writeUploadedTombstone(segmentID: segmentID)
                    }
                }
                try? await transferEngine.initialize()
                await mobileSegmentUploader?.resumeFromDisk()
                await transferEngine.enableDispatch()
            },
            isPaired: { credentials.snapshot().pairing != nil },
            allowsActivity: { true },
            isObserverSustaining: { observerManager.isSustainingBackground },
            isAnyBackgroundSustaining: {
                isBackgroundTunnelSustained(
                    locationSustaining: locationManager.isSustainingBackground,
                    finishSyncingActive: false,
                    observerAudioSustaining: observerManager.isSustainingBackground
                )
            },
            totals: {
                sendableUploadTotals(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchHolder,
                    share: shareTransferHolder
                )
            },
            inFlight: {
                uploadInFlight(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchHolder,
                    share: shareTransferHolder
                )
            },
            backoff: {
                uploadBackoff(mirror: transferMirror)
            },
            driveDrain: {
                await driveUploadDrain(
                    mobileSegment: mobileSegmentUploader,
                    transferEngine: transferEngine,
                    shareImportStore: shareImportStore,
                    shareTransferHolder: shareTransferHolder,
                    diagnosticLog: nil,
                    watchDrain: nil
                )
            },
            fallbackScenePhase: { fallbackScenePhase },
            makeAsserter: { asserter },
            clock: ImmediateWakeObserverClock(),
            settleInterval: .milliseconds(10)
        )
        coordinator.install(on: observerManager)
        rig.coordinator = coordinator

        if bootstrapInitially {
            await coordinator.bootstrapTransferIfNeeded()
        }
        if connectInitially {
            let ingestDescriptor = TransferEndpointDescriptor(
                destinationKind: .observerIngest,
                path: "/app/devices/ingest"
            )
            tunnelManager.startNetworkMonitoring()
            await tunnelManager.connect()
            try await Self.waitUntil("initial endpoint resolver ready") {
                if case .available = await endpointResolver.resolve(ingestDescriptor) {
                    return true
                }
                return false
            }
        }

        self.addTeardownBlock { @MainActor in
            coordinator.cancelBackgroundDrain()
            _ = await observerManager.stopSession()
            await locationManager.stop()
            tunnelManager.stopNetworkMonitoring()
            await tunnelManager.disconnect()
            await transferEngine.pause()
            transferTransport.invalidateAndCancel()
            let deadline = ContinuousClock.now + .seconds(3)
            while await transferEngine.snapshot().counters.inFlightCount > 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            TransferURLProtocol.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        return rig
    }

    func makeStandaloneTunnelManager(
        transport: MockCFTunnelTransport,
        pathSource: SustainMockPathSource,
        isBackgroundSustained: @escaping @MainActor () -> Bool
    ) -> TunnelManager {
        let pairing = Self.fixturePairing()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-endpoints.json")
        return TunnelManager(
            transport: transport,
            endpointCache: EndpointCache(fileURL: tempFile),
            pathMonitor: PathMonitor(source: pathSource),
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {},
            probeWatchdogPolicy: ProbeWatchdogPolicy(
                healthyInterval: .seconds(60),
                silentFailureLimit: 2,
                activeInboundFailureLimit: 6
            ),
            isBackgroundSustained: isBackgroundSustained,
            automaticallyReconnectOnCredentialReplacement: false,
            ageGate: AgeSignalGate(isEnabled: false, store: AgeSignalStore(suiteName: "standalone.\(UUID().uuidString)"))
        )
    }

    nonisolated static func fixturePairing() -> StoredPairing {
        let instanceID = "instance-sustain-test"
        let claims: [String: Any] = [
            "iss": "independent-issuer",
            "sub": "instance:\(instanceID)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instanceID,
            "iat": 1_767_225_600,
            "exp": 2_082_758_400,
            "jti": "sustain-jti",
        ]
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).sig"
        return StoredPairing(
            instanceID: instanceID,
            homeLabel: "sol",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "b", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .enrolled(deviceToken: token, expiresAt: nil),
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 8676, scope: "")],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }
}

private final class SustainMockPathSource: PathMonitoringSource, @unchecked Sendable {
    var handler: (@Sendable (NetworkPathStatus) -> Void)?

    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        self.handler = onPathChange
    }

    func stop() {
        self.handler = nil
    }

    func trigger(_ status: NetworkPathStatus) {
        self.handler?(status)
    }
}

@MainActor
private final class SustainSpyBackgroundTaskAsserter: BackgroundTaskAsserting {
    var beginReturn = true
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var handler: (@MainActor () -> Void)?

    func begin(expirationHandler: @escaping @MainActor () -> Void) -> Bool {
        self.beginCount += 1
        self.handler = expirationHandler
        return self.beginReturn
    }

    func end() {
        self.endCount += 1
    }
}

@MainActor
private final class SustainingFlagBox {
    var value = false
}

/// Uses real short sleeps for tiny settle intervals while keeping explicit `advance(by:)`
/// control for multi-second ObserverManager / MobileSegmentEngine timers.
@MainActor
private final class ImmediateWakeObserverClock: ObserverClock {
    private let inner: MockObserverClock

    init(now: Date = Date(timeIntervalSince1970: 1_780_480_800)) {
        self.inner = MockObserverClock(now: now)
    }

    var pendingSleeperCount: Int {
        self.inner.pendingSleeperCount
    }

    func now() -> Date {
        self.inner.now()
    }

    func sleep(for duration: Duration) async throws {
        if duration < .seconds(1) {
            try await Task.sleep(for: duration)
            return
        }
        try await self.inner.sleep(for: duration)
    }

    func advance(by seconds: TimeInterval) {
        self.inner.advance(by: seconds)
    }
}

@MainActor
private final class ManualFinishSyncingScheduling: FinishSyncingScheduling {
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any FinishSyncingTaskHandle) -> Void
    ) -> Bool {
        true
    }

    func submit(identifier: String, title: String, subtitle: String) throws {}
}

@MainActor
private final class ManualFinishSyncingTaskHandle: FinishSyncingTaskHandle {
    var isCancelled = false
    private let expireOnSetExpiration: Bool
    private(set) var completedSuccess: Bool?

    init(expireOnSetExpiration: Bool = false) {
        self.expireOnSetExpiration = expireOnSetExpiration
    }

    func setProgressTotal(_ total: Int) {}
    func setProgressCompleted(_ completed: Int) {}
    func updateTitle(_ title: String, subtitle: String) {}

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        if self.expireOnSetExpiration {
            handler()
        }
    }

    func complete(success: Bool) {
        self.completedSuccess = success
    }
}
