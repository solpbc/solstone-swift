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

    func testFailedAppendRetainsLaterPayloadBehindRecoveredPendingRecord() throws {
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

    func testUnretainablePayloadReturnsTypedFaultInsteadOfDroppingSilently() {
        let rootURL = self.makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let io = FaultInjectingOmiLaunchCaptureIO()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { rootURL }, io: io)
        XCTAssertTrue(ingress.arm())
        io.failNext(.open)

        XCTAssertEqual(ingress.ingest(Data("lost".utf8)), .fault(shouldCancelConnection: true))
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

    static func peripheral(audioNotifying: Bool = true) -> OmiPeripheralDescriptor {
        OmiPeripheralDescriptor(
            id: UUID(), name: "omi", state: .connected,
            services: [OmiServiceDescriptor(id: OmiUUIDs.audioServiceID, characteristics: [Self.audio(Data(), isNotifying: audioNotifying)])]
        )
    }

    static func audio(_ value: Data, isNotifying: Bool = true) -> OmiCharacteristicDescriptor {
        OmiCharacteristicDescriptor(
            id: OmiCharacteristicID(serviceID: OmiUUIDs.audioServiceID, characteristicID: OmiUUIDs.audioDataCharacteristicID),
            properties: [.notify], isNotifying: isNotifying, value: value
        )
    }
}
