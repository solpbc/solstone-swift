// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchCaptureIngressTests: XCTestCase {
    func testConstructionEdgeDurablyRoutesSynchronousStartAudio() throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        port.onStart = { delegate in
            let manager = delegate as! OmiSourceManager
            manager.handleRestoredPeripheral(peripheral)
            manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("first".utf8)), error: nil)
        }

        _ = makeOmiSourceManager(
            appGroupRoot: { rootURL }, io: io, generationID: generation,
            defaults: defaults, clock: MockObserverClock(), bluetoothPort: port
        )

        let recovery = self.recovery(rootURL: rootURL, generation: generation, io: io)
        XCTAssertEqual(recovery.verifiedPrefixNextSequence, 1)
        XCTAssertNil(recovery.boundaryReason)
        guard case .lease(let lease) = self.reader(rootURL: rootURL, generation: generation, io: io).lease() else { return XCTFail("expected capture lease") }
        XCTAssertEqual(lease.records.map(\.payload), [Data("first".utf8)])
    }

    func testPreReadinessCaptureIsOrderedAndDoesNotDecode() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral(audioNotifying: true)
        port.seed(peripheral)
        let manager = makeOmiSourceManager(
            appGroupRoot: { rootURL }, io: io, generationID: generation,
            defaults: defaults, clock: clock, bluetoothPort: port
        )

        manager.handleRestoredPeripheral(peripheral)
        manager.handleRestoredPeripheral(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("one".utf8)), error: nil)
        clock.advance(by: 1)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("two".utf8)), error: nil)

        XCTAssertFalse(manager.hasOpusDecoder)
        XCTAssertFalse(manager.didAttemptWriterStart)
        let reader = self.reader(rootURL: rootURL, generation: generation, io: io)
        guard case .lease(let first) = reader.lease() else { return XCTFail("expected ordered lease") }
        XCTAssertEqual(first.records.map(\.payload), [Data("one".utf8), Data("two".utf8)])
        XCTAssertEqual(first.records.map(\.acquiredAtUnixMicros), [100_000_000, 101_000_000])

        await manager.openLaunchReadiness()
        await manager.openLaunchReadiness()
        XCTAssertEqual(port.setNotifyCallCount, 0)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("three".utf8)), error: nil)
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: generation, io: io).verifiedPrefixNextSequence, 3)
        XCTAssertFalse(manager.hasOpusDecoder)
        XCTAssertFalse(manager.didAttemptWriterStart)
    }

    func testDisabledLaunchIsInertUntilExplicitEnable() throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: false)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(
            appGroupRoot: { rootURL }, io: io, generationID: generation,
            defaults: defaults, clock: MockObserverClock(), bluetoothPort: port
        )

        manager.handleRestoredPeripheral(peripheral)
        manager.handleConnected(peripheral)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data(), isNotifying: true), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("disabled".utf8)), error: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: self.captureURL(rootURL: rootURL, generation: generation).path))
        XCTAssertFalse(manager.hasOpusDecoder)
        XCTAssertFalse(manager.didAttemptWriterStart)
        XCTAssertGreaterThanOrEqual(port.cancelConnectionCallCount, 1)

        manager.enable()
        manager.enable()
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.captureURL(rootURL: rootURL, generation: generation).path))
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("enabled".utf8)), error: nil)
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: generation, io: io).verifiedPrefixNextSequence, 1)
    }

    func testEnableThenDisableBeforeReadinessRemainsInert() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: false)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        manager.enable()
        manager.disable()
        manager.handleRestoredPeripheral(peripheral)
        manager.handleConnected(peripheral)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data()), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("disabled".utf8)), error: nil)
        await manager.handleDisconnected(peripheral, timestamp: 0, isReconnecting: true, error: nil)
        await manager.openLaunchReadiness()

        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: generation, io: io).verifiedPrefixNextSequence, 0)
        XCTAssertFalse(manager.hasOpusDecoder)
        XCTAssertFalse(manager.didAttemptWriterStart)
        XCTAssertFalse(manager.isAudioSubscribed)
    }

    func testFailedArmCancelsThenResumesOnceWithoutReplaying() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        io.failNext(.open)
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        port.onStart = { delegate in
            let manager = delegate as! OmiSourceManager
            manager.handleRestoredPeripheral(peripheral)
            manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("lost".utf8)), error: nil)
        }
        let manager = makeOmiSourceManager(
            appGroupRoot: { rootURL }, io: io, generationID: generation,
            defaults: defaults, clock: MockObserverClock(), bluetoothPort: port
        )

        XCTAssertGreaterThanOrEqual(port.cancelConnectionCallCount, 1)
        XCTAssertEqual(manager.effectiveConnectionState(now: Date()), .needsAttention(.audioUnavailable))
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: generation, io: io).verifiedPrefixNextSequence, 0)

        io.clearFaults()
        let didResume = await manager.resumeLaunchCaptureOnce()
        XCTAssertTrue(didResume)
        let didResumeAgain = await manager.resumeLaunchCaptureOnce()
        XCTAssertFalse(didResumeAgain)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("future".utf8)), error: nil)
        guard case .lease(let lease) = self.reader(rootURL: rootURL, generation: generation, io: io).lease() else { return XCTFail("expected resumed capture") }
        XCTAssertEqual(lease.records.map(\.payload), [Data("future".utf8)])
    }

    func testCommittedAppendGapRetainsLaterPayloadAsNoncontiguousSuffixAfterRetry() throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(
            appGroupRoot: { rootURL }, io: io, generationID: generation,
            defaults: defaults, clock: MockObserverClock(), bluetoothPort: port
        )

        io.failBarrier(onCall: 2)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("P".utf8)), error: nil)
        io.clearFaults()
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("Q".utf8)), error: nil)

        guard case .lease(let lease) = self.reader(rootURL: rootURL, generation: generation, io: io).lease() else {
            return XCTFail("expected retained prefix")
        }
        XCTAssertEqual(lease.records.map(\.payload), [Data("P".utf8), Data("Q".utf8)])
        XCTAssertEqual(port.cancelConnectionCallCount, 1)
        XCTAssertEqual(manager.effectiveConnectionState(now: Date()), .needsAttention(.audioUnavailable))
    }

    func testUnretainablePayloadReturnsTypedNotRetainedInsteadOfDroppingSilently() {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { rootURL }, io: io)
        XCTAssertTrue(ingress.arm())
        io.failNext(.open)
        io.failNext(.open)

        XCTAssertEqual(ingress.ingest(.payload(Data("lost".utf8))), .notRetained)
        XCTAssertTrue(ingress.isLatched)
    }

    func testReorderedCaptureCallbacksAccountForEachPayloadExactlyOnce() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        manager.handleCentralStateUpdate(.poweredOn)
        manager.handleRestoredPeripheral(peripheral)
        manager.handleConnected(peripheral)
        manager.handleRestoredPeripheral(peripheral)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data()), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("B".utf8)), error: nil)
        manager.disable()
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("disabled".utf8)), error: nil)
        await manager.openLaunchReadiness()

        guard case .lease(let lease) = self.reader(rootURL: rootURL, generation: generation, io: io).lease() else { return XCTFail("expected capture lease") }
        XCTAssertEqual(lease.records.map(\.payload), [Data("A".utf8), Data("B".utf8)])
        XCTAssertFalse(manager.hasOpusDecoder)
        XCTAssertFalse(manager.didAttemptWriterStart)
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: generation, io: io).boundaryReason, nil)
    }

    func testTypedErrorCreatesOrderedDurableGapBeforeLaterPayload() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        await manager.openLaunchReadiness()
        manager.handleConnected(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data()), error: Self.streamError)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C".utf8)), error: nil)

        self.assertSingleBoundary(
            rootURL: rootURL, generation: generation, io: io,
            expectedPayloads: [Data("A".utf8)], port: port, manager: manager
        )
    }

    func testEmptyValueCreatesOrderedDurableGapBeforeLaterPayload() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        await manager.openLaunchReadiness()
        manager.handleConnected(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data()), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C".utf8)), error: nil)

        self.assertSingleBoundary(
            rootURL: rootURL, generation: generation, io: io,
            expectedPayloads: [Data("A".utf8)], port: port, manager: manager
        )
    }

    func testInFlightPayloadAfterBoundaryDoesNotCreateContiguousSuffix() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        await manager.openLaunchReadiness()
        manager.handleConnected(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data()), error: Self.streamError)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C".utf8)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C2".utf8)), error: nil)

        self.assertSingleBoundary(
            rootURL: rootURL, generation: generation, io: io,
            expectedPayloads: [Data("A".utf8)], port: port, manager: manager
        )
    }

    func testReservationAndFlowControlFailuresRemainIndependentlyObservable() async throws {
        let reservationRootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: reservationRootURL) }
        let reservationDefaults = try self.defaults(enabled: true)
        defer { reservationDefaults.removePersistentDomain(forName: reservationDefaults.description) }
        let reservationIO = FaultInjectingOmiLaunchCaptureIO()
        let reservationPort = MockOmiBluetoothPort()
        let reservationGeneration = UUID()
        let reservationPeripheral = Self.peripheral()
        reservationPort.seed(reservationPeripheral)
        let reservationManager = makeOmiSourceManager(appGroupRoot: { reservationRootURL }, io: reservationIO, generationID: reservationGeneration, defaults: reservationDefaults, clock: MockObserverClock(), bluetoothPort: reservationPort)

        await reservationManager.openLaunchReadiness()
        reservationManager.handleConnected(reservationPeripheral)
        reservationManager.handleUpdatedValue(reservationPeripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        reservationIO.failNext(.open)
        reservationManager.handleUpdatedValue(reservationPeripheral, characteristic: Self.audio(Data()), error: Self.streamError)
        reservationManager.handleUpdatedValue(reservationPeripheral, characteristic: Self.audio(Data("C".utf8)), error: nil)

        let reservationRecovery = self.recovery(rootURL: reservationRootURL, generation: reservationGeneration, io: reservationIO)
        XCTAssertEqual(reservationRecovery.verifiedPrefixNextSequence, 1)
        XCTAssertEqual(reservationRecovery.boundarySequence, 1)
        guard case .lease(let reservationLease) = self.reader(rootURL: reservationRootURL, generation: reservationGeneration, io: reservationIO).lease() else {
            return XCTFail("expected reservation boundary lease")
        }
        XCTAssertEqual(reservationLease.records.map(\.payload), [Data("A".utf8)])
        XCTAssertEqual(reservationManager.effectiveConnectionState(now: Date()), .needsAttention(.audioUnavailable))
        XCTAssertEqual(reservationPort.cancelConnectionCallCount, 1)

        let flowRootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: flowRootURL) }
        let flowDefaults = try self.defaults(enabled: true)
        defer { flowDefaults.removePersistentDomain(forName: flowDefaults.description) }
        let flowIO = FaultInjectingOmiLaunchCaptureIO()
        let flowPort = MockOmiBluetoothPort()
        flowPort.setNotifySucceeds = false
        let flowGeneration = UUID()
        let flowPeripheral = Self.peripheral()
        flowPort.seed(flowPeripheral)
        let flowManager = makeOmiSourceManager(appGroupRoot: { flowRootURL }, io: flowIO, generationID: flowGeneration, defaults: flowDefaults, clock: MockObserverClock(), bluetoothPort: flowPort)

        await flowManager.openLaunchReadiness()
        flowManager.handleConnected(flowPeripheral)
        flowManager.handleUpdatedValue(flowPeripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        flowManager.handleUpdatedValue(flowPeripheral, characteristic: Self.audio(Data()), error: Self.streamError)

        XCTAssertEqual(self.recovery(rootURL: flowRootURL, generation: flowGeneration, io: flowIO).boundarySequence, 1)
        XCTAssertEqual(flowPort.setNotifyCalls.filter { !$0.2 }.count, 1)
        XCTAssertEqual(flowPort.cancelConnectionCallCount, 1)
        XCTAssertEqual(flowManager.effectiveConnectionState(now: Date()), .needsAttention(.audioUnavailable))
    }

    func testLatchPersistsUntilEnabledReconnectSubscriptionRotatesGenerationOnce() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.reconnectPeripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        await manager.openLaunchReadiness()
        manager.handleConnected(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8), isNotifying: false), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data(), isNotifying: false), error: Self.streamError)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data(), isNotifying: true), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C".utf8), isNotifying: true), error: nil)
        XCTAssertEqual(manager.activeLaunchCaptureGenerationID, generation)
        XCTAssertEqual(manager.effectiveConnectionState(now: Date()), .needsAttention(.audioUnavailable))

        await manager.handleDisconnected(peripheral, timestamp: 0, isReconnecting: false, error: nil)
        manager.disable()
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data(), isNotifying: true), error: nil)
        XCTAssertEqual(manager.activeLaunchCaptureGenerationID, generation)

        manager.enable()
        manager.handleConnected(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.codec(), error: nil)
        manager.handleRestoredPeripheral(peripheral)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data(), isNotifying: true), error: nil)

        let rotatedGeneration = try XCTUnwrap(manager.activeLaunchCaptureGenerationID)
        XCTAssertNotEqual(rotatedGeneration, generation)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C".utf8), isNotifying: true), error: nil)
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: generation, io: io).boundarySequence, 1)
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: rotatedGeneration, io: io).verifiedPrefixNextSequence, 1)
        guard case .lease(let lease) = self.reader(rootURL: rootURL, generation: rotatedGeneration, io: io).lease() else {
            return XCTFail("expected rotated capture lease")
        }
        XCTAssertEqual(lease.records.map(\.payload), [Data("C".utf8)])
    }

    func testAlreadyLiveReadinessRotatesAfterPreReadinessNotification() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.reconnectPeripheral()
        let alreadyLivePeripheral = Self.reconnectPeripheral(id: peripheral.id, audioNotifying: true)
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8), isNotifying: false), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data(), isNotifying: false), error: Self.streamError)
        await manager.handleDisconnected(peripheral, timestamp: 0, isReconnecting: false, error: nil)
        manager.handleUpdatedValue(alreadyLivePeripheral, characteristic: Self.codec(), error: nil)
        manager.handleUpdatedNotificationState(alreadyLivePeripheral, characteristic: Self.audio(Data(), isNotifying: true), error: nil)
        port.seed(alreadyLivePeripheral)

        await manager.openLaunchReadiness()

        let rotatedGeneration = try XCTUnwrap(manager.activeLaunchCaptureGenerationID)
        XCTAssertNotEqual(rotatedGeneration, generation)
        manager.handleUpdatedValue(alreadyLivePeripheral, characteristic: Self.audio(Data("C".utf8), isNotifying: true), error: nil)
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: generation, io: io).boundarySequence, 1)
        XCTAssertEqual(self.recovery(rootURL: rootURL, generation: rotatedGeneration, io: io).verifiedPrefixNextSequence, 1)
    }

    func testStalePostDisconnectNotificationDoesNotRotateBeforeReconnect() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.reconnectPeripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        await manager.openLaunchReadiness()
        manager.handleConnected(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8), isNotifying: false), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data(), isNotifying: false), error: Self.streamError)
        await manager.handleDisconnected(peripheral, timestamp: 0, isReconnecting: false, error: nil)

        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data(), isNotifying: true), error: nil)
        XCTAssertEqual(manager.activeLaunchCaptureGenerationID, generation)
    }

    func testContiguousPayloadTwinDoesNotRequestAttentionOrFlowControl() throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C".utf8)), error: nil)

        let recovery = self.recovery(rootURL: rootURL, generation: generation, io: io)
        XCTAssertEqual(recovery.verifiedPrefixNextSequence, 2)
        XCTAssertNil(recovery.boundaryReason)
        XCTAssertFalse(manager.writerFaulted)
        XCTAssertEqual(port.cancelConnectionCallCount, 0)
        XCTAssertTrue(port.setNotifyCalls.filter { !$0.2 }.isEmpty)
    }

    func testReorderedRepeatedCallbacksCreateAtMostOneBoundaryAndDisabledCallbacksStayInert() async throws {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try self.defaults(enabled: true)
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let port = MockOmiBluetoothPort()
        let generation = UUID()
        let peripheral = Self.peripheral()
        port.seed(peripheral)
        let manager = makeOmiSourceManager(appGroupRoot: { rootURL }, io: io, generationID: generation, defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        await manager.openLaunchReadiness()
        manager.handleConnected(peripheral)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("A".utf8)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data()), error: Self.streamError)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data()), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data("C".utf8)), error: nil)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data(), isNotifying: false), error: nil)
        await manager.handleDisconnected(peripheral, timestamp: 0, isReconnecting: false, error: Self.streamError)
        await manager.openLaunchReadiness()
        self.assertSingleBoundary(
            rootURL: rootURL, generation: generation, io: io,
            expectedPayloads: [Data("A".utf8)], port: port, manager: manager
        )
        let cancellationCountBeforeDisable = port.cancelConnectionCallCount
        let notifyDisableCountBeforeDisable = port.setNotifyCalls.filter { !$0.2 }.count
        manager.disable()
        manager.handleUpdatedValue(peripheral, characteristic: Self.audio(Data()), error: Self.streamError)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audio(Data(), isNotifying: true), error: nil)
        XCTAssertEqual(port.cancelConnectionCallCount, cancellationCountBeforeDisable + 3)
        XCTAssertEqual(port.setNotifyCalls.filter { !$0.2 }.count, notifyDisableCountBeforeDisable)
    }
}

private extension OmiLaunchCaptureIngressTests {
    func defaults(enabled: Bool) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OmiLaunchCaptureIngressTests-\(UUID().uuidString)"))
        defaults.set(enabled, forKey: "omiSource.enabled")
        return defaults
    }

    func makeRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureIngressTests-\(UUID().uuidString)", isDirectory: true)
    }

    func captureURL(rootURL: URL, generation: UUID) -> URL {
        OmiLaunchCaptureFormat.fileURL(
            rootURL: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true),
            generationID: generation
        )
    }

    func recovery(rootURL: URL, generation: UUID, io: any OmiLaunchCaptureIO) -> OmiLaunchCaptureScanResult {
        OmiLaunchCaptureRecovery(
            rootURL: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true),
            generationID: generation,
            io: io
        ).recover()
    }

    func reader(rootURL: URL, generation: UUID, io: any OmiLaunchCaptureIO) -> OmiLaunchCaptureLeaseReader {
        OmiLaunchCaptureLeaseReader(
            rootURL: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true),
            generationID: generation,
            io: io
        )
    }

    func assertSingleBoundary(
        rootURL: URL,
        generation: UUID,
        io: any OmiLaunchCaptureIO,
        expectedPayloads: [Data],
        port: MockOmiBluetoothPort,
        manager: OmiSourceManager
    ) {
        let recovery = self.recovery(rootURL: rootURL, generation: generation, io: io)
        XCTAssertEqual(recovery.verifiedPrefixNextSequence, UInt64(expectedPayloads.count))
        XCTAssertEqual(recovery.boundarySequence, UInt64(expectedPayloads.count))
        XCTAssertEqual(recovery.boundaryReason, .incompleteReservedRecord)
        guard case .lease(let lease) = self.reader(rootURL: rootURL, generation: generation, io: io).lease() else {
            return XCTFail("expected boundary prefix lease")
        }
        XCTAssertEqual(lease.records.map(\.payload), expectedPayloads)
        XCTAssertEqual(manager.effectiveConnectionState(now: Date()), .needsAttention(.audioUnavailable))
        XCTAssertEqual(port.setNotifyCalls.filter { !$0.2 }.count, 1)
        XCTAssertEqual(port.cancelConnectionCallCount, 1)
    }

    static func peripheral(audioNotifying: Bool = true) -> OmiPeripheralDescriptor {
        OmiPeripheralDescriptor(
            id: UUID(), name: "omi", state: .connected,
            services: [OmiServiceDescriptor(id: OmiUUIDs.audioServiceID, characteristics: [Self.audio(Data(), isNotifying: audioNotifying)])]
        )
    }

    static func reconnectPeripheral(id: UUID = UUID(), audioNotifying: Bool = false) -> OmiPeripheralDescriptor {
        OmiPeripheralDescriptor(
            id: id, name: "omi", state: .connected,
            services: [OmiServiceDescriptor(
                id: OmiUUIDs.audioServiceID,
                characteristics: [Self.codec(), Self.audio(Data(), isNotifying: audioNotifying)]
            )]
        )
    }

    static func codec() -> OmiCharacteristicDescriptor {
        OmiCharacteristicDescriptor(
            id: OmiCharacteristicID(serviceID: OmiUUIDs.audioServiceID, characteristicID: OmiUUIDs.codecCharacteristicID),
            properties: [.read], isNotifying: false, value: Data([20])
        )
    }

    static let streamError = NSError(domain: "OmiLaunchCaptureIngressTests", code: 1)

    static func audio(_ value: Data, isNotifying: Bool = true) -> OmiCharacteristicDescriptor {
        OmiCharacteristicDescriptor(
            id: OmiCharacteristicID(serviceID: OmiUUIDs.audioServiceID, characteristicID: OmiUUIDs.audioDataCharacteristicID),
            properties: [.notify], isNotifying: isNotifying, value: value
        )
    }
}
