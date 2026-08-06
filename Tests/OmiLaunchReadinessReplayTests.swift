// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchReadinessReplayTests: XCTestCase {
    func testReadinessReplayDrivesEarliestMissingPrerequisiteOnce() async throws {
        enum Scenario: CaseIterable {
            case noServices
            case needsCodecRead
            case needsSubscribe
            case alreadyLive
            case disconnected
        }

        for scenario in Scenario.allCases {
            let defaults = try self.makeDefaults()
            defer { defaults.removePersistentDomain(forName: defaults.description) }
            let port = MockOmiBluetoothPort()
            let services: [OmiServiceDescriptor]
            switch scenario {
            case .noServices, .disconnected:
                services = []
            case .needsCodecRead, .needsSubscribe, .alreadyLive:
                services = [Self.audioService(audioNotifying: scenario == .alreadyLive)]
            }
            let peripheral = Self.peripheral(
                state: scenario == .disconnected ? .disconnected : .connected,
                services: services
            )
            port.seed(peripheral)
            let manager = OmiSourceManager(
                defaults: defaults,
                clock: MockObserverClock(),
                bluetoothPort: port
            )

            manager.enable()
            manager.handleCentralStateUpdate(.poweredOn)
            switch scenario {
            case .noServices:
                manager.handleConnected(peripheral)
            case .needsCodecRead:
                manager.handleDiscoveredCharacteristics(peripheral, service: Self.audioService(), error: nil)
            case .needsSubscribe:
                manager.handleUpdatedValue(peripheral, characteristic: Self.codecCharacteristic(), error: nil)
            case .alreadyLive:
                manager.handleUpdatedValue(peripheral, characteristic: Self.codecCharacteristic(), error: nil)
                manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audioCharacteristic(isNotifying: true), error: nil)
            case .disconnected:
                manager.handleRestoredPeripheral(peripheral)
            }

            await manager.openLaunchReadiness()

            switch scenario {
            case .noServices:
                self.assertEffects(port, discoverServices: 1)
            case .needsCodecRead:
                self.assertEffects(port, readValue: 1)
            case .needsSubscribe:
                self.assertEffects(port, setNotify: 1)
            case .alreadyLive:
                self.assertEffects(port)
                XCTAssertTrue(manager.hasOpusDecoder)
                XCTAssertTrue(manager.isAudioSubscribed)
                XCTAssertEqual(manager.connectionState, .connected)
            case .disconnected:
                self.assertEffects(port, connect: 1)
            }
        }
    }

    func testReorderedAndRepeatedCallbacksBeforeReadinessCoalesceToOneAdvance() async throws {
        let defaults = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let port = MockOmiBluetoothPort()
        let connected = Self.peripheral(state: .connected, services: [Self.audioService(audioNotifying: true)])
        let disconnected = Self.peripheral(id: connected.id, state: .disconnected, services: connected.services)
        port.seed(connected)
        let manager = OmiSourceManager(defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)

        manager.enable()
        manager.handleCentralStateUpdate(.poweredOn)
        manager.handleRestoredPeripheral(connected)
        manager.handleConnected(connected)
        manager.handleConnected(connected)
        manager.handleDiscoveredServices(connected, error: nil)
        manager.handleDiscoveredServices(connected, error: nil)
        manager.handleDiscoveredCharacteristics(connected, service: Self.audioService(audioNotifying: true), error: nil)
        manager.handleDiscoveredCharacteristics(connected, service: Self.audioService(audioNotifying: true), error: nil)
        manager.handleUpdatedValue(connected, characteristic: Self.codecCharacteristic(), error: nil)
        manager.handleUpdatedValue(connected, characteristic: Self.codecCharacteristic(), error: nil)
        manager.handleUpdatedNotificationState(connected, characteristic: Self.audioCharacteristic(isNotifying: true), error: nil)
        manager.handleUpdatedNotificationState(connected, characteristic: Self.audioCharacteristic(isNotifying: true), error: nil)
        port.setState(.disconnected, for: connected.id)
        await manager.handleDisconnected(
            disconnected,
            timestamp: Date().timeIntervalSinceReferenceDate,
            isReconnecting: false,
            error: nil
        )

        await manager.openLaunchReadiness()
        await manager.openLaunchReadiness()

        self.assertEffects(port, connect: 1)
        XCTAssertFalse(manager.hasOpusDecoder)
        XCTAssertFalse(manager.didAttemptWriterStart)
        XCTAssertNil(defaults.string(forKey: "omiSource.lastConnectedPeripheralID"))
    }

    func testDisabledSourceIgnoresAndCancelsEveryLateCallback() async throws {
        enum Scenario: CaseIterable {
            case coldLaunchDisabled
            case enabledThenDisabled
            case persistedDisabledThroughReadiness
        }

        for scenario in Scenario.allCases {
            let defaults = try self.makeDefaults()
            defer { defaults.removePersistentDomain(forName: defaults.description) }
            let port = MockOmiBluetoothPort()
            let peripheral = Self.peripheral(state: .connected, services: [Self.audioService()])
            port.seed(peripheral)
            let manager = OmiSourceManager(defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)
            var rawIngressCount = 0
            manager.onRawAudioIngress = { _ in rawIngressCount += 1 }

            switch scenario {
            case .coldLaunchDisabled:
                break
            case .enabledThenDisabled:
                manager.enable()
                manager.disable()
            case .persistedDisabledThroughReadiness:
                await manager.openLaunchReadiness()
            }

            await self.driveDisabledCallbacks(manager: manager, peripheral: peripheral)
            await manager.openLaunchReadiness()

            XCTAssertFalse(manager.enabled)
            XCTAssertEqual(manager.connectionState, .disconnected)
            XCTAssertNil(manager.deferredReadinessPeripheralID)
            XCTAssertNil(defaults.string(forKey: "omiSource.lastConnectedPeripheralID"))
            self.assertEffects(port, cancelAtLeast: 1)
            XCTAssertFalse(manager.hasOpusDecoder)
            XCTAssertFalse(manager.didAttemptWriterStart)
            XCTAssertEqual(rawIngressCount, 0)

            port.resetEffectHistory()
            manager.handleCentralStateUpdate(.poweredOn)
            manager.enable()
            self.assertEffects(port, connect: 1)
        }
    }

    func testRawAudioIngressSurvivesPreReadinessWithoutDecodeOrStorage() async throws {
        let defaults = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchReadinessReplayTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let harness = makeTransferCutoverHarness(rootURL: rootURL.appendingPathComponent("Transfers", isDirectory: true))
        let writerRoot = rootURL.appendingPathComponent("Omi", isDirectory: true)
        let writer = OmiSegmentWriter(transferEnqueuer: harness.enqueuer, cacheRootURL: writerRoot, clock: MockObserverClock())
        let port = MockOmiBluetoothPort()
        let peripheral = Self.peripheral(state: .connected, services: [Self.audioService(audioNotifying: true)])
        port.seed(peripheral)
        let manager = OmiSourceManager(defaults: defaults, clock: MockObserverClock(), bluetoothPort: port)
        manager.omiSegmentWriter = writer
        var rawIngressCount = 0
        var decodedSampleHandoffs = 0
        manager.onRawAudioIngress = { _ in rawIngressCount += 1 }
        manager.onDecodedSamples = { _ in decodedSampleHandoffs += 1 }

        manager.enable()
        manager.handleCentralStateUpdate(.poweredOn)
        manager.handleUpdatedValue(peripheral, characteristic: Self.codecCharacteristic(), error: nil)
        manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audioCharacteristic(isNotifying: true), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audioCharacteristic(value: Self.audioPacket(0)), error: nil)
        manager.handleUpdatedValue(peripheral, characteristic: Self.audioCharacteristic(value: Self.audioPacket(1)), error: nil)

        XCTAssertEqual(rawIngressCount, 2)
        XCTAssertEqual(decodedSampleHandoffs, 0)
        XCTAssertFalse(manager.hasOpusDecoder)
        XCTAssertFalse(manager.didAttemptWriterStart)
        XCTAssertEqual(port.setNotifyCallCount, 0)
        XCTAssertEqual(port.cancelConnectionCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writerRoot.path))

        await manager.openLaunchReadiness()
        manager.handleUpdatedValue(peripheral, characteristic: Self.audioCharacteristic(value: Self.audioPacket(2)), error: nil)
        XCTAssertEqual(rawIngressCount, 3)
    }
}

private extension OmiLaunchReadinessReplayTests {
    func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "OmiLaunchReadinessReplayTests-\(UUID().uuidString)"))
    }

    func driveDisabledCallbacks(manager: OmiSourceManager, peripheral: OmiPeripheralDescriptor) async {
        let service = Self.audioService()
        let codec = Self.codecCharacteristic()
        let audio = Self.audioCharacteristic(value: Self.audioPacket(0))
        let error = NSError(domain: "OmiLaunchReadinessReplayTests", code: 1)

        for _ in 0..<2 {
            manager.handleCentralStateUpdate(.poweredOn)
            manager.handleCentralStateUpdate(.poweredOff)
            manager.handleRestoredPeripheral(peripheral)
            manager.handleConnected(peripheral)
            manager.handleFailedToConnect(peripheral, error: error)
            manager.handleDiscoveredServices(peripheral, error: nil)
            manager.handleDiscoveredServices(peripheral, error: error)
            manager.handleDiscoveredCharacteristics(peripheral, service: service, error: nil)
            manager.handleDiscoveredCharacteristics(peripheral, service: service, error: error)
            manager.handleUpdatedValue(peripheral, characteristic: codec, error: nil)
            manager.handleUpdatedValue(peripheral, characteristic: audio, error: nil)
            manager.handleDidReadRSSI(peripheral, rssi: -55, error: nil)
            manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audioCharacteristic(isNotifying: true), error: nil)
            manager.handleUpdatedNotificationState(peripheral, characteristic: Self.audioCharacteristic(), error: error)
            await manager.handleDisconnected(
                peripheral,
                timestamp: Date().timeIntervalSinceReferenceDate,
                isReconnecting: false,
                error: error
            )
        }
    }

    func assertEffects(
        _ port: MockOmiBluetoothPort,
        connect: Int = 0,
        discoverServices: Int = 0,
        discoverCharacteristics: Int = 0,
        readValue: Int = 0,
        readRSSI: Int = 0,
        setNotify: Int = 0,
        cancel: Int = 0,
        cancelAtLeast: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(port.connectCallCount, connect, file: file, line: line)
        XCTAssertEqual(port.discoverServicesCallCount, discoverServices, file: file, line: line)
        XCTAssertEqual(port.discoverCharacteristicsCallCount, discoverCharacteristics, file: file, line: line)
        XCTAssertEqual(port.readValueCallCount, readValue, file: file, line: line)
        XCTAssertEqual(port.readRSSICallCount, readRSSI, file: file, line: line)
        XCTAssertEqual(port.setNotifyCallCount, setNotify, file: file, line: line)
        if let cancelAtLeast {
            XCTAssertGreaterThanOrEqual(port.cancelConnectionCallCount, cancelAtLeast, file: file, line: line)
        } else {
            XCTAssertEqual(port.cancelConnectionCallCount, cancel, file: file, line: line)
        }
    }

    static func peripheral(
        id: UUID = UUID(),
        state: OmiPeripheralConnectionState,
        services: [OmiServiceDescriptor]
    ) -> OmiPeripheralDescriptor {
        OmiPeripheralDescriptor(id: id, name: "omi", state: state, services: services)
    }

    static func audioService(audioNotifying: Bool = false) -> OmiServiceDescriptor {
        OmiServiceDescriptor(
            id: OmiUUIDs.audioServiceID,
            characteristics: [
                Self.codecCharacteristic(),
                Self.audioCharacteristic(isNotifying: audioNotifying),
            ]
        )
    }

    static func codecCharacteristic() -> OmiCharacteristicDescriptor {
        OmiCharacteristicDescriptor(
            id: OmiCharacteristicID(
                serviceID: OmiUUIDs.audioServiceID,
                characteristicID: OmiUUIDs.codecCharacteristicID
            ),
            properties: [.read],
            isNotifying: false,
            value: Data([20])
        )
    }

    static func audioCharacteristic(
        isNotifying: Bool = false,
        value: Data? = nil
    ) -> OmiCharacteristicDescriptor {
        OmiCharacteristicDescriptor(
            id: OmiCharacteristicID(
                serviceID: OmiUUIDs.audioServiceID,
                characteristicID: OmiUUIDs.audioDataCharacteristicID
            ),
            properties: [.notify],
            isNotifying: isNotifying,
            value: value
        )
    }

    static func audioPacket(_ packetNumber: UInt16) -> Data {
        var data = Data([
            UInt8(packetNumber & 0x00FF),
            UInt8(packetNumber >> 8),
            0,
        ])
        data.append(0xF8)
        return data
    }
}
