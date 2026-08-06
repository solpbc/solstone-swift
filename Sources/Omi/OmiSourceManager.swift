// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import CoreBluetooth
import Foundation
import Observation
import UIKit
import os

private struct OmiPendingSubscribe: Sendable {
    let identity: OmiEventIdentity
    let connectedAt: Date
}

@MainActor
@Observable
final class OmiSourceManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated static let restoreIdentifier = "app.solstone.swift.omi-source"
    private nonisolated static let enabledKey = "omiSource.enabled"
    private nonisolated static let lastConnectedPeripheralIDKey = "omiSource.lastConnectedPeripheralID"

    private nonisolated let log = Logger(subsystem: "app.solstone.swift", category: "omi")

    var enabled: Bool
    var managerState: OmiBluetoothManagerState = .unknown
    var connectionState: OmiSourceState = .disconnected
    var connectedPeripheralName: String?
    var connectedPeripheralID: UUID?
    var connectedRSSI: Int?
    var lastKnownBattery: TimedReading<Int>?
    var lastKnownSignal: TimedReading<Int>?
    var firmware: OmiReadState<String> = .notRead
    var manufacturer: OmiReadState<String> = .notRead
    var model: OmiReadState<String> = .notRead
    var hardwareRevision: OmiReadState<String> = .notRead
    var battery: OmiReadState<Int> = .notRead
    var codec: OmiReadState<OmiAudioCodecInfo> = .notRead
    var isAudioSubscribed = false
    var writerFaulted = false
    var audioUnsubscribedWhileConnected = false
    var audioPackets = 0
    var audioFrames = 0
    var audioDecodeOK = 0
    var audioDecodeErrors = 0
    var audioGaps = 0
    var audioOutOfOrder = 0
    var audioMalformed = 0
    var audioMarkers = 0
    var lastMarkerDate: Date?
    var lastAudioAt: Date?
    var uptime = OmiUptimeAccumulator()
    var lastDisconnectedAt: Date?
    var isSystemReconnecting = false
    var reconnectStartedAt: Date?
    var lastReconnectLatencySeconds: TimeInterval?
    var reconnectCount = 0
    var eventRing = OmiEventRing()
    let diagnostics: OmiDiagnostics
    let heardTally: OmiHeardTally

    @ObservationIgnored var onDecodedSamples: (@MainActor ([Int16]) -> Void)?
    @ObservationIgnored var omiSegmentWriter: OmiSegmentWriter?

    @ObservationIgnored private let bluetoothPort: any OmiBluetoothPort
    @ObservationIgnored private var peripheralsByID: [UUID: OmiPeripheralDescriptor] = [:]
    @ObservationIgnored private var characteristicsByID: [OmiCharacteristicID: OmiCharacteristicDescriptor] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var reassembler = OmiAudioReassembler()
    @ObservationIgnored private var opusDecoder: OmiOpusAudioDecoder?
    @ObservationIgnored private var pendingConnectionID: UUID?
    @ObservationIgnored private var manuallyDisconnected = false
    @ObservationIgnored private var didLogPoweredOn = false
    @ObservationIgnored private var isLaunchReady = false
    @ObservationIgnored private var initialConnectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var wantsEnableOnPowerOn = false
    @ObservationIgnored private var phoneSampleTask: Task<Void, Never>?
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private var previousBatteryMonitoringEnabled: Bool?
    @ObservationIgnored private var silentEpisodeRecoveryFired = false
    @ObservationIgnored private(set) var didAttemptWriterStart = false
    @ObservationIgnored private var lastLoggedAudioHealth: OmiAudioHealth?
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var pendingReconnectIdentity: OmiEventIdentity?
    @ObservationIgnored private var pendingSubscribe: OmiPendingSubscribe?
    @ObservationIgnored private var currentConnectionMTUAtConnect: Int?
    @ObservationIgnored private var currentConnectionMTUAtSubscribeConfirm: Int?
    @ObservationIgnored private var currentConnectionFirstAudioAt: Date?
    @ObservationIgnored private var currentConnectionConnectToFirstAudioSeconds: TimeInterval?
    @ObservationIgnored private var lastSilentAttributionAt: Date?
    @ObservationIgnored private var lastSeenMarkerEpoch: UInt32?
    @ObservationIgnored private(set) var deferredReadinessPeripheralID: UUID?
    @ObservationIgnored var onRawAudioIngress: (@MainActor (Data) -> Void)?

    var hasOpusDecoder: Bool { self.opusDecoder != nil }

    private var isOmiWorkDisabled: Bool {
        OmiSourceLogic.isDisabled(enabled: self.enabled, manuallyDisconnected: self.manuallyDisconnected)
    }

    init(
        defaults: UserDefaults = .standard,
        diagnostics: OmiDiagnostics = OmiDiagnostics(),
        heardTally: OmiHeardTally = OmiHeardTally(),
        clock: any ObserverClock = SystemObserverClock(),
        bluetoothPort: any OmiBluetoothPort = LiveOmiBluetoothPort()
    ) {
        self.defaults = defaults
        self.diagnostics = diagnostics
        self.heardTally = heardTally
        self.clock = clock
        self.bluetoothPort = bluetoothPort
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.lastKnownBattery = diagnostics.payload.pendantBatteryTrend.last.map {
            TimedReading(value: $0.level, at: $0.timestamp)
        }
        self.lastKnownSignal = nil
        super.init()
        self.bluetoothPort.start(delegate: self)
    }

    func enable() {
        self.enabled = true
        self.persistEnabled(true)
        self.manuallyDisconnected = false
        guard self.isLaunchReady else { return }
        self.enableBatteryMonitoringIfNeeded()
        self.startPhoneSampleLoop()

        guard self.managerState == .poweredOn else {
            self.wantsEnableOnPowerOn = true
            let attention = OmiSourceLogic.attention(for: self.managerState) ?? .bluetoothOff
            self.connectionState = .needsAttention(attention)
            self.log.error("omi unavailable: \(attention.displayString, privacy: .public)")
            return
        }

        self.wantsEnableOnPowerOn = false
        self.cancelInitialConnectTimeout()
        guard !self.isTryingOrConnected else { return }

        let connected = self.bluetoothPort.retrieveConnectedPeripherals(serviceIDs: [
            OmiUUIDs.audioServiceID,
            OmiUUIDs.storageServiceID
        ]).first

        let persistedID = OmiSourceLogic.persistedPeripheralID(
            from: self.defaults.string(forKey: Self.lastConnectedPeripheralIDKey)
        )
        let persisted = persistedID.flatMap { id in self.bluetoothPort.retrievePeripherals(identifiers: [id]).first }

        guard let descriptor = connected ?? persisted else {
            self.connectionState = .needsAttention(.pendantNotFound)
            self.log.error("omi pendant not found")
            return
        }

        self.omiSegmentWriter?.start()
        self.beginConnect(peripheralID: descriptor.id, isReconnect: false)
    }

    func startSegmentWriterIfNeeded() {
        guard self.isLaunchReady else { return }
        guard !self.isOmiWorkDisabled else { return }
        guard !self.didAttemptWriterStart else { return }
        self.didAttemptWriterStart = true
        self.omiSegmentWriter?.start()
    }

    func noteWriterFault() {
        self.writerFaulted = true
        self.refreshDiagnosticDecodeCounters(persist: true)
    }

    func freezeSegmentMetadata() -> OmiSegmentMetadataSnapshot {
        let deltas = self.diagnostics.frozenSegmentDeltas()
        let reconnectEvents: [OmiSegmentMetadata.ReconnectEvent] = deltas.reconnectEvents.compactMap { event -> OmiSegmentMetadata.ReconnectEvent? in
            guard let processID = event.processID,
                  let sequence = event.sequence,
                  let revision = event.revision
            else { return nil }
            return OmiSegmentMetadata.ReconnectEvent(
                processID: processID,
                sequence: sequence,
                revision: revision,
                disconnectedAt: event.timestamp,
                appState: event.appStateAtDrop,
                latencySeconds: event.timeToReconnect
            )
        }
        let subscribeEvents: [OmiSegmentMetadata.SubscribeEvent] = deltas.subscribeSamples.compactMap { sample -> OmiSegmentMetadata.SubscribeEvent? in
            guard let processID = sample.processID,
                  let sequence = sample.sequence,
                  let revision = sample.revision,
                  let connectedAt = sample.connectedAt
            else { return nil }
            let isCompleted = revision > 1
            return OmiSegmentMetadata.SubscribeEvent(
                processID: processID,
                sequence: sequence,
                revision: revision,
                connectedAt: connectedAt,
                subscribedAt: isCompleted ? sample.timestamp : nil,
                latencySeconds: isCompleted ? sample.latencySeconds : nil,
                appState: sample.appState
            )
        }
        let phoneSample = self.diagnostics.payload.phoneSamples.last
        let firmware: String?
        if case .value(let value) = self.firmware, !value.isEmpty {
            firmware = value
        } else {
            firmware = nil
        }
        return OmiSegmentMetadataSnapshot(
            metadata: OmiSegmentMetadata(
                connectionState: self.segmentConnectionState,
                processID: self.diagnostics.payload.processID,
                processStartedAt: self.diagnostics.payload.processStartedAt,
                pendantBatteryLevel: self.lastKnownBattery?.value,
                pendantBatteryAt: self.lastKnownBattery?.at,
                phoneBatteryLevel: phoneSample?.batteryLevel,
                phoneBatteryAt: phoneSample?.timestamp,
                phoneBatteryState: phoneSample?.batteryState,
                phoneThermalState: phoneSample?.thermalState,
                firmware: firmware,
                connectToFirstAudioSeconds: self.currentConnectionConnectToFirstAudioSeconds,
                reconnectCount: self.reconnectCount,
                reconnectEvents: reconnectEvents,
                subscribeEvents: subscribeEvents
            ),
            frozenTokens: deltas.tokens
        )
    }

    func acknowledgeSegmentMetadata(tokens: [OmiSegmentMetadataToken]) {
        self.diagnostics.acknowledgeSegmentMetadata(tokens: tokens)
    }

    func effectiveConnectionState(now: Date) -> OmiSourceState {
        OmiSourceLogic.effectiveConnectionState(
            connectionState: self.connectionState,
            writerFaulted: self.writerFaulted,
            audioUnsubscribedWhileConnected: self.audioUnsubscribedWhileConnected,
            reconnectStartedAt: self.reconnectStartedAt,
            isAudioSubscribed: self.isAudioSubscribed,
            lastAudioAt: self.lastAudioAt,
            connectedSince: self.diagnostics.payload.uptime.connectedSince,
            now: now
        )
    }

    func disable() {
        self.enabled = false
        self.persistEnabled(false)
        self.wantsEnableOnPowerOn = false
        self.stopPhoneSampleLoop()
        self.restoreBatteryMonitoringIfNeeded()
        self.manuallyDisconnected = true
        self.cancelInitialConnectTimeout()
        let pendingPeripheralID = self.pendingConnectionID ?? self.connectedPeripheralID
        if let pendingPeripheralID {
            self.bluetoothPort.cancelConnection(peripheralID: pendingPeripheralID)
        }
        self.omiSegmentWriter?.stop()
        self.clearConnectionArtifacts()
        self.writerFaulted = false
        self.audioUnsubscribedWhileConnected = false
        self.uptime.noteDisconnected(at: self.clock.now())
        self.connectionState = .disconnected
        self.log.info("omi stopped")
    }

    func resumeIfEnabled() async {
        guard self.defaults.bool(forKey: Self.enabledKey) else {
            self.enabled = false
            let ids = Set(self.peripheralsByID.keys).union([self.pendingConnectionID, self.connectedPeripheralID, self.deferredReadinessPeripheralID].compactMap { $0 })
            for id in ids {
                self.bluetoothPort.cancelConnection(peripheralID: id)
            }
            self.clearConnectionArtifacts()
            return
        }

        guard self.isLaunchReady else {
            self.enabled = true
            return
        }

        if self.managerState == .poweredOn {
            self.enable()
        } else {
            self.enabled = true
            self.enableBatteryMonitoringIfNeeded()
            self.startPhoneSampleLoop()
            self.wantsEnableOnPowerOn = true
        }
    }

    func openLaunchReadiness() async {
        guard !self.isLaunchReady else { return }
        self.isLaunchReady = true
        if self.deferredReadinessPeripheralID != nil {
            self.replayReadinessState()
        } else {
            await self.resumeIfEnabled()
        }
    }

    func handleWillRestoreState(restoredCount: Int) {
        self.log.info("omi restore received: \(restoredCount, privacy: .public) peripherals")
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = LiveOmiBluetoothPort.managerStateDescriptor(for: central.state)
        MainActor.assumeIsolated {
            self.handleCentralStateUpdate(state)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let restoredCount = peripherals.count
        let descriptors = peripherals.map { peripheral in
            MainActor.assumeIsolated { self.bluetoothPort.register(peripheral) }
        }
        MainActor.assumeIsolated {
            self.handleWillRestoreState(restoredCount: restoredCount)
        }
        for descriptor in descriptors {
            MainActor.assumeIsolated {
                self.handleRestoredPeripheral(descriptor)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        MainActor.assumeIsolated {
            let descriptor = self.bluetoothPort.register(peripheral)
            self.handleConnected(descriptor)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            let descriptor = self.bluetoothPort.register(peripheral)
            self.handleFailedToConnect(descriptor, error: error)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let descriptor = self.bluetoothPort.register(peripheral)
            await self.handleDisconnected(
                descriptor,
                timestamp: timestamp,
                isReconnecting: isReconnecting,
                error: error
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            let descriptor = self.bluetoothPort.register(peripheral)
            self.handleDiscoveredServices(descriptor, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            let descriptor = self.bluetoothPort.register(peripheral)
            let serviceDescriptor = LiveOmiBluetoothPort.serviceDescriptor(for: service)
            self.handleDiscoveredCharacteristics(descriptor, service: serviceDescriptor, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            let descriptor = self.bluetoothPort.register(peripheral)
            let characteristicDescriptor = LiveOmiBluetoothPort.characteristicDescriptor(for: characteristic)
            self.handleUpdatedValue(descriptor, characteristic: characteristicDescriptor, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            let descriptor = self.bluetoothPort.register(peripheral)
            let characteristicDescriptor = LiveOmiBluetoothPort.characteristicDescriptor(for: characteristic)
            self.handleUpdatedNotificationState(descriptor, characteristic: characteristicDescriptor, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            let descriptor = self.bluetoothPort.register(peripheral)
            self.handleDidReadRSSI(descriptor, rssi: RSSI, error: error)
        }
    }
}

extension OmiSourceManager {
    func handleAudioData(_ data: Data) {
        guard !self.isOmiWorkDisabled else { return }
        self.onRawAudioIngress?(data)
        let output = self.reassembler.ingest(data)

        for marker in output.markers {
            let observedAt = self.clock.now()
            if let lastSeenMarkerEpoch,
               OmiDiagnosticsLogic.isPendantReboot(
                   epochBefore: lastSeenMarkerEpoch,
                   epochAfter: marker.epoch
               )
            {
                self.diagnostics.appendPendantRebootEvent(
                    observedAt: observedAt,
                    epochBefore: lastSeenMarkerEpoch,
                    epochAfter: marker.epoch
                )
            }
            self.lastSeenMarkerEpoch = marker.epoch
            self.lastMarkerDate = Date(timeIntervalSince1970: Double(marker.epoch))
            self.log.info("omi audio marker: \(marker.epoch, privacy: .public)")
        }

        guard self.isLaunchReady else { return }

        let sink = self.onDecodedSamples.map { isolatedSink in
            { samples in
                MainActor.assumeIsolated {
                    isolatedSink(samples)
                }
            }
        }
        let deltas = OmiSourceLogic.emitDecodedFrames(
            output.completedFrames,
            decode: { frame in
                MainActor.assumeIsolated {
                    self.opusDecoder?.decode(frame)
                }
            },
            sink: sink
        )
        self.audioDecodeOK += deltas.decodeOK
        self.audioDecodeErrors += deltas.decodeErrors
        self.applyAudioCounterSnapshot()
        self.refreshDiagnosticDecodeCounters(persist: false)
        if deltas.decodeOK > 0 {
            self.startSegmentWriterIfNeeded()
            let now = self.clock.now()
            self.noteFirstAudioIfNeeded(at: now)
            self.attributeOpenConnectedSilentGap(at: now)
            self.lastAudioAt = now
            self.diagnostics.noteDecodedSamples(at: now)
            self.lastSilentAttributionAt = nil
            self.evaluateAudioRecovery(now: now)
            // this branch guarantees this-connection decode success (per-batch delta, not lifetime)
            if let recovered = OmiSourceLogic.recoveredConnectionState(
                current: self.connectionState,
                audioIsLive: true
            ) {
                self.connectionState = recovered
            }
        }
    }

    func buildOpusDecoder() {
        do {
            self.opusDecoder = try OmiOpusAudioDecoder()
        } catch {
            self.opusDecoder = nil
            self.log.error("omi opus decoder unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleCentralStateUpdate(_ state: OmiBluetoothManagerState) {
        self.managerState = state

        guard !self.isOmiWorkDisabled else {
            if let pendingConnectionID {
                self.bluetoothPort.cancelConnection(peripheralID: pendingConnectionID)
            }
            return
        }

        if state == .poweredOn {
            if !self.didLogPoweredOn {
                self.didLogPoweredOn = true
                self.log.info("omi bluetooth ready")
            }
            if !self.manuallyDisconnected,
               let pendingConnectionID,
               let peripheral = self.peripheralsByID[pendingConnectionID],
               self.connectedPeripheralID == nil
            {
                if self.isLaunchReady {
                    self.beginConnect(peripheral, isReconnect: true)
                }
            }
            if self.wantsEnableOnPowerOn,
               self.pendingConnectionID == nil,
               self.connectedPeripheralID == nil
            {
                if self.isLaunchReady {
                    self.wantsEnableOnPowerOn = false
                    self.enable()
                }
            }
            return
        }

        guard !self.manuallyDisconnected,
              self.isTryingOrConnected,
              let attention = OmiSourceLogic.attention(for: state)
        else {
            return
        }
        self.connectionState = .needsAttention(attention)
        self.log.error("omi unavailable: \(attention.displayString, privacy: .public)")
    }

    func replayReadinessState() {
        guard self.isLaunchReady,
              !self.isOmiWorkDisabled,
              let peripheralID = self.deferredReadinessPeripheralID
        else {
            return
        }
        self.deferredReadinessPeripheralID = nil
        guard let peripheral = self.bluetoothPort.descriptor(peripheralID: peripheralID) else {
            return
        }
        self.advanceReadiness(for: peripheral)
    }
}

private extension OmiSourceManager {
    var restoreServiceIDs: [String] {
        [
            OmiUUIDs.audioServiceID,
            OmiUUIDs.deviceInformationServiceID,
            OmiUUIDs.batteryServiceID,
            OmiUUIDs.storageServiceID
        ]
    }

    func beginConnect(_ peripheral: OmiPeripheralDescriptor, isReconnect: Bool) {
        guard !self.isOmiWorkDisabled else {
            self.bluetoothPort.cancelConnection(peripheralID: peripheral.id)
            return
        }
        self.cancelInitialConnectTimeout()
        self.pendingConnectionID = peripheral.id
        self.peripheralsByID[peripheral.id] = peripheral
        self.connectionState = isReconnect ? .reconnecting : .connecting
        guard self.isLaunchReady else { return }
        self.bluetoothPort.connect(peripheralID: peripheral.id, enablesAutoReconnect: true)
        self.log.info("omi \(isReconnect ? "reconnecting" : "connecting", privacy: .public)")

        guard !isReconnect else {
            return
        }

        let id = peripheral.id
        self.initialConnectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self,
                  !Task.isCancelled,
                  self.pendingConnectionID == id,
                  self.connectionState == .connecting
            else {
                return
            }
            self.connectionState = .needsAttention(.connectFailed("connection timed out"))
            self.log.error("omi connection timed out")
        }
    }

    func beginConnect(peripheralID: UUID, isReconnect: Bool) {
        guard let peripheral = self.bluetoothPort.descriptor(peripheralID: peripheralID) ?? self.peripheralsByID[peripheralID] else {
            self.pendingConnectionID = peripheralID
            self.connectionState = isReconnect ? .reconnecting : .connecting
            guard self.isLaunchReady, !self.isOmiWorkDisabled else { return }
            self.bluetoothPort.connect(peripheralID: peripheralID, enablesAutoReconnect: true)
            return
        }
        self.beginConnect(peripheral, isReconnect: isReconnect)
    }

    var isTryingOrConnected: Bool {
        if self.pendingConnectionID != nil {
            return true
        }
        if let connectedPeripheralID,
           let peripheral = self.bluetoothPort.descriptor(peripheralID: connectedPeripheralID)
        {
            return peripheral.state != .disconnected
        }
        switch self.connectionState {
        case .connecting, .connected, .reconnecting:
            return true
        case .disconnected, .needsAttention:
            return false
        }
    }

    var currentConnectedPeripheral: OmiPeripheralDescriptor? {
        guard let connectedPeripheralID else { return nil }
        return self.bluetoothPort.descriptor(peripheralID: connectedPeripheralID)
    }

}

extension OmiSourceManager {
    func handleRestoredPeripheral(_ peripheral: OmiPeripheralDescriptor) {
        self.advanceReadiness(for: peripheral)
    }

    func advanceReadiness(for peripheral: OmiPeripheralDescriptor) {
        guard !self.isOmiWorkDisabled else {
            self.bluetoothPort.cancelConnection(peripheralID: peripheral.id)
            return
        }
        self.peripheralsByID[peripheral.id] = peripheral
        self.cacheRestoredCharacteristics(in: peripheral)

        let audioCharacteristic = self.audioCharacteristic(in: peripheral)
        let hasAudioService = peripheral.services.contains { $0.id.matches(OmiUUIDs.audioServiceID) }
        let action = OmiSourceLogic.readinessAction(
            peripheralState: peripheral.state,
            hasAudioService: hasAudioService,
            isAudioNotifying: audioCharacteristic?.isNotifying == true,
            codec: self.codec
        )

        self.log.info("omi restore action: \(String(describing: action), privacy: .public)")
        guard self.isLaunchReady else {
            self.deferredReadinessPeripheralID = peripheral.id
            return
        }
        switch action {
        case .rearmConnect:
            self.beginConnect(peripheral, isReconnect: true)
        case .discoverServices:
            let didAdopt = self.adoptConnectedPeripheralIfNeeded(peripheral)
            self.connectionState = .connected
            if didAdopt {
                self.beginConnectionInstrumentation(
                    now: self.clock.now(),
                    expectsSubscribeConfirm: true
                )
            }
            self.bluetoothPort.discoverServices(peripheralID: peripheral.id, serviceIDs: self.restoreServiceIDs)
        case .readCodec:
            let didAdopt = self.adoptConnectedPeripheralIfNeeded(peripheral)
            self.connectionState = .connected
            if didAdopt {
                self.beginConnectionInstrumentation(
                    now: self.clock.now(),
                    expectsSubscribeConfirm: true
                )
            }
            if let codecCharacteristic = self.characteristic(for: OmiUUIDs.codecCharacteristicID),
               codecCharacteristic.properties.contains(.read)
            {
                self.bluetoothPort.readValue(peripheralID: peripheral.id, characteristicID: codecCharacteristic.id)
            } else if let audioService = peripheral.services.first(where: { $0.id.matches(OmiUUIDs.audioServiceID) }) {
                self.bluetoothPort.discoverCharacteristics(peripheralID: peripheral.id, serviceID: audioService.id)
            } else {
                self.connectionState = .needsAttention(.audioUnavailable)
                self.log.error("omi audio unavailable after restore")
            }
        case .needsAttention(let attention):
            _ = self.adoptConnectedPeripheralIfNeeded(peripheral)
            self.connectionState = .needsAttention(attention)
            self.log.error("omi restore needs attention: \(attention.displayString, privacy: .public)")
        case .subscribeAudio:
            let didAdopt = self.adoptConnectedPeripheralIfNeeded(peripheral)
            self.connectionState = .connected
            if didAdopt {
                self.beginConnectionInstrumentation(
                    now: self.clock.now(),
                    expectsSubscribeConfirm: true
                )
            }
            if let audioCharacteristic {
                self.setAudioNotify(enabled: true, characteristic: audioCharacteristic)
            } else if let audioService = peripheral.services.first(where: { $0.id.matches(OmiUUIDs.audioServiceID) }) {
                self.bluetoothPort.discoverCharacteristics(peripheralID: peripheral.id, serviceID: audioService.id)
            } else {
                self.connectionState = .needsAttention(.audioUnavailable)
                self.log.error("omi audio unavailable after restore")
            }
        case .alreadyLive:
            let didAdopt = self.adoptConnectedPeripheralIfNeeded(peripheral)
            self.connectionState = .connected
            if didAdopt {
                self.beginConnectionInstrumentation(
                    now: self.clock.now(),
                    expectsSubscribeConfirm: false,
                    appendAdoptedLatency: true
                )
            }
            self.isAudioSubscribed = true
            if self.opusDecoder == nil {
                self.buildOpusDecoder()
            }
        }
    }

    func handleConnected(_ peripheral: OmiPeripheralDescriptor) {
        guard !self.isOmiWorkDisabled else {
            self.bluetoothPort.cancelConnection(peripheralID: peripheral.id)
            return
        }
        guard self.isLaunchReady else {
            self.deferredReadinessPeripheralID = peripheral.id
            return
        }
        self.cancelInitialConnectTimeout()
        self.pendingConnectionID = nil
        self.adoptConnectedPeripheral(peripheral)
        let now = self.clock.now()

        if let reconnectStartedAt {
            let latency = now.timeIntervalSince(reconnectStartedAt)
            self.lastReconnectLatencySeconds = latency
            self.reconnectCount += 1
            if let pendingReconnectIdentity {
                self.eventRing.completeReconnect(identity: pendingReconnectIdentity, timeToReconnect: latency)
                self.diagnostics.recordReconnect(identity: pendingReconnectIdentity, latency: latency)
            }
            self.reconnectStartedAt = nil
            self.pendingReconnectIdentity = nil
            self.isSystemReconnecting = false
        }

        self.connectionState = .connected
        self.beginConnectionInstrumentation(now: now, expectsSubscribeConfirm: true)
        self.attributeOpenConnectedSilentGap(at: now)
        self.diagnostics.recordConnected()
        self.lastSilentAttributionAt = nil
        self.uptime.noteConnected(at: now)
        self.connectedRSSI = nil
        self.lastAudioAt = nil
        self.silentEpisodeRecoveryFired = false
        self.lastLoggedAudioHealth = nil
        self.writerFaulted = false
        self.audioUnsubscribedWhileConnected = false
        self.resetReadState()
        self.clearAudioState()
        self.characteristicsByID.removeAll()
        if self.isLaunchReady {
            self.readRSSI()
        }
        self.log.info("omi connected")
        if self.isLaunchReady {
            self.bluetoothPort.discoverServices(peripheralID: peripheral.id, serviceIDs: nil)
        }
    }

    func handleFailedToConnect(_ peripheral: OmiPeripheralDescriptor, error: (any Error)?) {
        guard !self.isOmiWorkDisabled else { return }
        self.cancelInitialConnectTimeout()
        self.pendingConnectionID = nil
        let reason = error?.localizedDescription ?? "unknown error"
        self.connectionState = .needsAttention(.connectFailed(reason))
        self.clearConnectionArtifacts()
        self.log.error("omi connection failed: \(reason, privacy: .public)")
    }

    func handleDisconnected(
        _ peripheral: OmiPeripheralDescriptor,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) async {
        guard !self.isOmiWorkDisabled else { return }
        let disconnectedAt = Date(timeIntervalSinceReferenceDate: timestamp)
        self.lastDisconnectedAt = disconnectedAt
        self.uptime.noteDisconnected(at: disconnectedAt)
        self.attributeOpenConnectedSilentGap(at: disconnectedAt)

        let decision = OmiSourceLogic.reconnectDecision(
            isManualDisconnect: self.manuallyDisconnected,
            isReconnecting: isReconnecting
        )

        if !self.manuallyDisconnected {
            do {
                self.diagnostics.beginCoalescing()
                defer {
                    self.diagnostics.endCoalescing()
                }

                let identity = self.diagnostics.allocateEventIdentity()
                let event = OmiSourceEvent(
                    timestamp: disconnectedAt,
                    reason: error?.localizedDescription ?? "link lost",
                    appStateAtDrop: self.currentAppStateString,
                    timeToReconnect: nil,
                    identity: identity
                )
                self.eventRing.append(event)
                self.diagnostics.recordDisconnected(event: event)
                self.pendingReconnectIdentity = identity
                self.lastSilentAttributionAt = nil
            }
        }

        // Set edge state before freezing; defer cleanup/rearm so live readings survive and no new connection starts before audio closes.
        switch decision {
        case .stayDisconnected:
            self.connectionState = .disconnected
        case .systemReconnecting:
            self.isSystemReconnecting = true
            self.reconnectStartedAt = disconnectedAt
            self.connectionState = .reconnecting
        case .rearmConnect:
            self.isSystemReconnecting = false
            self.reconnectStartedAt = disconnectedAt
            self.connectionState = .reconnecting
        }

        if self.isLaunchReady {
            self.omiSegmentWriter?.finalizeOpenChunkForDisconnect()
        }

        switch decision {
        case .stayDisconnected:
            self.clearConnectionArtifacts()
            self.log.info("omi stopped")
        case .systemReconnecting:
            self.clearTransientConnectionState()
            self.log.info("omi reconnecting through bluetooth")
        case .rearmConnect:
            self.clearTransientConnectionState()
            if self.isLaunchReady {
                self.beginConnect(peripheral, isReconnect: true)
            }
            self.log.info("omi reconnect armed")
        }
    }

    func handleDiscoveredServices(_ peripheral: OmiPeripheralDescriptor, error: (any Error)?) {
        guard !self.isOmiWorkDisabled else {
            self.bluetoothPort.cancelConnection(peripheralID: peripheral.id)
            return
        }
        guard self.isLaunchReady else {
            self.deferredReadinessPeripheralID = peripheral.id
            return
        }
        if let error {
            self.connectionState = .needsAttention(.connectFailed(error.localizedDescription))
            self.log.error("omi profile discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let services = peripheral.services
        self.log.info("omi profiles discovered: \(services.count, privacy: .public)")
        if self.isLaunchReady {
            for service in services {
                self.bluetoothPort.discoverCharacteristics(peripheralID: peripheral.id, serviceID: service.id)
            }
        }
    }

    func handleDiscoveredCharacteristics(
        _ peripheral: OmiPeripheralDescriptor,
        service: OmiServiceDescriptor,
        error: (any Error)?
    ) {
        guard !self.isOmiWorkDisabled else {
            self.bluetoothPort.cancelConnection(peripheralID: peripheral.id)
            return
        }
        guard self.isLaunchReady else {
            self.deferredReadinessPeripheralID = peripheral.id
            return
        }
        if let error {
            self.log.error("omi characteristic discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let characteristics = service.characteristics
        for characteristic in characteristics {
            self.characteristicsByID[characteristic.id] = characteristic
        }

        self.markAbsentKnownFieldsUnavailable(for: service, characteristics: characteristics)
        self.log.info("omi characteristics discovered: \(characteristics.count, privacy: .public)")

        if self.isLaunchReady {
            for characteristic in characteristics where characteristic.properties.contains(.read) {
                if self.isAutoReadCharacteristic(characteristic.id.characteristicID) {
                    self.bluetoothPort.readValue(peripheralID: peripheral.id, characteristicID: characteristic.id)
                }
            }
        }
    }

    func handleUpdatedValue(
        _ peripheral: OmiPeripheralDescriptor,
        characteristic: OmiCharacteristicDescriptor,
        error: (any Error)?
    ) {
        guard !self.isOmiWorkDisabled else {
            self.bluetoothPort.cancelConnection(peripheralID: peripheral.id)
            return
        }
        if characteristic.id.characteristicID.matches(OmiUUIDs.audioDataCharacteristicID) {
            if let error {
                self.log.error("omi audio stream failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let data = characteristic.value, !data.isEmpty else {
                self.log.error("omi audio stream empty")
                return
            }
            self.handleAudioData(data)
            return
        }

        guard self.isLaunchReady else {
            self.deferredReadinessPeripheralID = peripheral.id
            if error != nil {
                self.markKnownFieldUnavailable(for: characteristic.id.characteristicID)
            } else if let data = characteristic.value, !data.isEmpty,
                      characteristic.id.characteristicID.matches(OmiUUIDs.codecCharacteristicID)
            {
                _ = self.updateKnownField(characteristic.id.characteristicID, data: data)
            }
            return
        }

        if let error {
            self.markKnownFieldUnavailable(for: characteristic.id.characteristicID)
            self.log.error("omi value read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let data = characteristic.value, !data.isEmpty else {
            self.markKnownFieldUnavailable(for: characteristic.id.characteristicID)
            self.log.error("omi value empty")
            return
        }

        if self.updateKnownField(characteristic.id.characteristicID, data: data) {
            return
        }
    }

    func handleUpdatedNotificationState(
        _ peripheral: OmiPeripheralDescriptor,
        characteristic: OmiCharacteristicDescriptor,
        error: (any Error)?
    ) {
        guard !self.isOmiWorkDisabled else {
            self.bluetoothPort.cancelConnection(peripheralID: peripheral.id)
            return
        }
        guard self.isLaunchReady else {
            self.deferredReadinessPeripheralID = peripheral.id
            if characteristic.id.characteristicID.matches(OmiUUIDs.audioDataCharacteristicID),
               error == nil,
               characteristic.isNotifying
            {
                self.isAudioSubscribed = true
            }
            return
        }
        guard characteristic.id.characteristicID.matches(OmiUUIDs.audioDataCharacteristicID) else {
            return
        }

        if let error {
            self.connectionState = .needsAttention(.audioUnavailable)
            self.log.error("omi audio notify failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        if characteristic.isNotifying {
            self.isAudioSubscribed = true
            self.audioUnsubscribedWhileConnected = false
            self.appendSubscribeLatencyIfNeeded(at: self.clock.now())
            self.resetAudioLiveState()
            if self.isLaunchReady {
                self.buildOpusDecoder()
            }
            self.log.info("omi audio stream enabled")
            if let recovered = OmiSourceLogic.recoveredConnectionState(
                current: self.connectionState,
                audioIsLive: characteristic.isNotifying
            ) {
                self.connectionState = recovered
            }
        } else {
            self.isAudioSubscribed = false
            if OmiSourceLogic.audioUnsubscribedWhileConnectedFault(
                connectionState: self.connectionState,
                isAudioNotifying: false
            ) {
                self.audioUnsubscribedWhileConnected = true
            }
            self.opusDecoder = nil
            self.log.info("omi audio stream disabled")
        }
    }

    func handleDidReadRSSI(
        _ peripheral: OmiPeripheralDescriptor,
        rssi RSSI: NSNumber,
        error: (any Error)?
    ) {
        guard !self.isOmiWorkDisabled else { return }
        if let error {
            self.log.info("omi rssi read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let level = RSSI.intValue
        let now = self.clock.now()
        self.connectedRSSI = level
        self.lastKnownSignal = TimedReading(value: level, at: now)
        self.diagnostics.recordSignal(level: level, at: now)
    }

}

private extension OmiSourceManager {
    func updateKnownField(_ characteristicID: String, data: Data) -> Bool {
        if characteristicID.matches(OmiUUIDs.batteryLevelCharacteristicID) {
            let rawByte = Self.byte(data, offset: 0)
            let level = Int(rawByte)
            let now = self.clock.now()
            self.battery = .value(level)
            self.lastKnownBattery = TimedReading(value: level, at: now)
            self.diagnostics.recordBattery(level: level, at: now, rawByte: rawByte)
            self.log.info("omi battery read")
            return true
        }

        if characteristicID.matches(OmiUUIDs.storageControlCharacteristicID) {
            guard data.count >= 4 else {
                self.log.error("omi storage backlog read too short: \(data.count, privacy: .public) bytes")
                return true
            }

            let usedBytes = Self.littleEndianUInt32(data, offset: 0)
            let fileCount = data.count >= 8 ? Self.littleEndianUInt32(data, offset: 4) : 0
            self.diagnostics.appendStorageBacklogSample(
                timestamp: self.clock.now(),
                usedBytes: usedBytes,
                rawHex: Self.hexString(data),
                fileCountUnconfirmed: fileCount
            )
            self.log.info("omi storage backlog read")
            return true
        }

        if characteristicID.matches(OmiUUIDs.codecCharacteristicID) {
            guard let byte = data.first else {
                self.codec = .unavailable
                self.log.error("omi codec unavailable")
                return true
            }
            let info = OmiAudioCodecInfo(
                rawByte: byte,
                label: OmiAudioCodecInfo.label(for: byte)
            )
            self.codec = .value(info)
            if info.isOpus {
                self.subscribeAudio()
            } else {
                self.connectionState = .needsAttention(.codecNotOpus)
                self.log.error("omi codec unsupported: \(info.label, privacy: .public)")
            }
            return true
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            self.markKnownFieldUnavailable(for: characteristicID)
            return self.isDeviceInfoCharacteristic(characteristicID)
        }

        if self.isDeviceInfoCharacteristic(characteristicID) {
            self.setStringField(characteristicID, state: .value(text))
            self.log.info("omi device info read")
            return true
        }

        return false
    }

    func subscribeAudio() {
        self.didAttemptWriterStart = false
        guard self.isLaunchReady else { return }
        guard !self.isOmiWorkDisabled else { return }
        guard let characteristic = self.characteristic(for: OmiUUIDs.audioDataCharacteristicID) else {
            self.connectionState = .needsAttention(.audioUnavailable)
            self.log.error("omi audio unavailable")
            return
        }
        self.setAudioNotify(enabled: true, characteristic: characteristic)
    }

    func setAudioNotify(enabled: Bool, characteristic: OmiCharacteristicDescriptor) {
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            self.connectionState = .needsAttention(.audioUnavailable)
            self.log.error("omi audio notify unavailable")
            return
        }
        guard self.isLaunchReady else { return }
        guard !self.isOmiWorkDisabled else { return }
        if let connectedPeripheralID { self.bluetoothPort.setNotify(peripheralID: connectedPeripheralID, characteristicID: characteristic.id, enabled: enabled) }
    }

    func readRSSI() {
        guard self.isLaunchReady,
              !self.isOmiWorkDisabled,
              self.connectionState == .connected,
              let connectedPeripheral = self.currentConnectedPeripheral
        else {
            return
        }
        self.bluetoothPort.readRSSI(peripheralID: connectedPeripheral.id)
    }

    func adoptConnectedPeripheral(_ peripheral: OmiPeripheralDescriptor) {
        self.connectedPeripheralName = peripheral.name ?? self.displayName(for: peripheral.id)
        self.connectedPeripheralID = peripheral.id
        self.peripheralsByID[peripheral.id] = peripheral
        self.defaults.set(
            OmiSourceLogic.storedPeripheralIDValue(for: peripheral.id),
            forKey: Self.lastConnectedPeripheralIDKey
        )
    }

    func adoptConnectedPeripheralIfNeeded(_ peripheral: OmiPeripheralDescriptor) -> Bool {
        guard self.connectedPeripheralID != peripheral.id else {
            self.peripheralsByID[peripheral.id] = peripheral
            return false
        }
        self.adoptConnectedPeripheral(peripheral)
        return true
    }

    func beginConnectionInstrumentation(
        now: Date,
        expectsSubscribeConfirm: Bool,
        appendAdoptedLatency: Bool = false
    ) {
        self.diagnostics.beginCoalescing()
        defer {
            self.diagnostics.endCoalescing()
        }

        self.clearPerConnectionInstrumentationState()
        self.connectedAt = now
        if expectsSubscribeConfirm || appendAdoptedLatency {
            let identity = self.diagnostics.allocateEventIdentity()
            self.pendingSubscribe = OmiPendingSubscribe(identity: identity, connectedAt: now)
            self.diagnostics.beginSubscribe(
                identity: identity,
                connectedAt: now,
                appState: self.currentAppStateString
            )
        } else {
            self.pendingSubscribe = nil
        }
        self.currentConnectionMTUAtConnect = self.currentConnectedPeripheral?.maximumWriteValueLength
        self.diagnostics.clearPerConnectionPointReadingsForNewConnection()
        self.diagnostics.setMTUAtConnect(self.currentConnectionMTUAtConnect)

        if appendAdoptedLatency {
            self.appendSubscribeLatencyIfNeeded(at: now)
        }
    }

    func appendSubscribeLatencyIfNeeded(at date: Date) {
        guard let pendingSubscribe else {
            return
        }

        self.diagnostics.completeSubscribe(
            identity: pendingSubscribe.identity,
            connectedAt: pendingSubscribe.connectedAt,
            subscribedAt: date,
            latencySeconds: date.timeIntervalSince(pendingSubscribe.connectedAt),
            appState: self.currentAppStateString
        )
        self.currentConnectionMTUAtSubscribeConfirm = self.currentConnectedPeripheral?.maximumWriteValueLength
        self.diagnostics.setMTUAtSubscribeConfirm(self.currentConnectionMTUAtSubscribeConfirm)
        self.pendingSubscribe = nil
    }

    func noteFirstAudioIfNeeded(at date: Date) {
        guard let connectedAt,
              self.currentConnectionFirstAudioAt == nil,
              self.currentConnectionConnectToFirstAudioSeconds == nil
        else {
            return
        }

        let latency = max(date.timeIntervalSince(connectedAt), 0)
        self.currentConnectionFirstAudioAt = date
        self.currentConnectionConnectToFirstAudioSeconds = latency
        self.diagnostics.setConnectToFirstAudioSeconds(latency)
    }

    func attributeOpenConnectedSilentGap(at date: Date) {
        guard let openStartedAt = self.diagnostics.payload.openConnectedSilentStartedAt else {
            self.lastSilentAttributionAt = nil
            return
        }

        let priorAttributionAt = self.lastSilentAttributionAt ?? openStartedAt
        let start = max(priorAttributionAt, openStartedAt)
        let elapsed = max(date.timeIntervalSince(start), 0)
        if elapsed > 0 {
            self.diagnostics.attributeConnectedSilentSeconds(
                elapsed: elapsed,
                appState: self.currentAppStateString
            )
            self.lastSilentAttributionAt = date
        } else {
            self.lastSilentAttributionAt = start
        }
    }

    func clearPerConnectionInstrumentationState() {
        self.connectedAt = nil
        self.pendingSubscribe = nil
        self.currentConnectionMTUAtConnect = nil
        self.currentConnectionMTUAtSubscribeConfirm = nil
        self.currentConnectionFirstAudioAt = nil
        self.currentConnectionConnectToFirstAudioSeconds = nil
        self.lastSilentAttributionAt = nil
    }

    func clearConnectionArtifacts() {
        self.connectedRSSI = nil
        self.connectedPeripheralName = nil
        self.connectedPeripheralID = nil
        self.characteristicsByID.removeAll()
        self.pendingConnectionID = nil
        self.reconnectStartedAt = nil
        self.isSystemReconnecting = false
        self.silentEpisodeRecoveryFired = false
        self.didAttemptWriterStart = false
        self.lastLoggedAudioHealth = nil
        self.writerFaulted = false
        self.audioUnsubscribedWhileConnected = false
        self.resetReadState()
        self.clearAudioState()
        self.clearPerConnectionInstrumentationState()
        self.deferredReadinessPeripheralID = nil
    }

    func clearTransientConnectionState() {
        self.connectedRSSI = nil
        self.characteristicsByID.removeAll()
        self.isAudioSubscribed = false
        self.opusDecoder = nil
        self.silentEpisodeRecoveryFired = false
        self.didAttemptWriterStart = false
        self.lastLoggedAudioHealth = nil
        self.audioUnsubscribedWhileConnected = false
        self.clearPerConnectionInstrumentationState()
    }

    func clearAudioState() {
        self.isAudioSubscribed = false
        self.opusDecoder = nil
        self.resetAudioLiveState()
    }

    func resetAudioLiveState() {
        self.reassembler = OmiAudioReassembler()
        self.audioPackets = 0
        self.audioFrames = 0
        self.audioDecodeOK = 0
        self.audioDecodeErrors = 0
        self.audioGaps = 0
        self.audioOutOfOrder = 0
        self.audioMalformed = 0
        self.audioMarkers = 0
        self.lastMarkerDate = nil
    }

    func applyAudioCounterSnapshot() {
        let snapshot = OmiSourceLogic.audioCounterSnapshot(
            reassembler: self.reassembler,
            decodeOK: self.audioDecodeOK,
            decodeErrors: self.audioDecodeErrors
        )
        self.audioPackets = snapshot.packets
        self.audioFrames = snapshot.frames
        self.audioGaps = snapshot.gaps
        self.audioOutOfOrder = snapshot.outOfOrder
        self.audioMalformed = snapshot.malformed
        self.audioMarkers = snapshot.markers
        self.audioDecodeOK = snapshot.decodeOK
        self.audioDecodeErrors = snapshot.decodeErrors
    }

    func refreshDiagnosticDecodeCounters(persist: Bool) {
        let droppedSamples = self.omiSegmentWriter?.droppedSamples ?? 0
        let failedOpens = self.omiSegmentWriter?.failedOpens ?? 0
        if persist {
            self.diagnostics.recordDecodeCounters(
                ok: self.audioDecodeOK,
                errors: self.audioDecodeErrors,
                gaps: self.audioGaps,
                outOfOrder: self.audioOutOfOrder,
                malformed: self.audioMalformed,
                droppedSamples: droppedSamples,
                failedOpens: failedOpens
            )
        } else {
            self.diagnostics.updateDecodeCounters(
                ok: self.audioDecodeOK,
                errors: self.audioDecodeErrors,
                gaps: self.audioGaps,
                outOfOrder: self.audioOutOfOrder,
                malformed: self.audioMalformed,
                droppedSamples: droppedSamples,
                failedOpens: failedOpens
            )
        }
    }

    func resetReadState() {
        self.firmware = .notRead
        self.manufacturer = .notRead
        self.model = .notRead
        self.hardwareRevision = .notRead
        self.battery = .notRead
        self.codec = .notRead
    }

    func persistEnabled(_ enabled: Bool) {
        self.defaults.set(enabled, forKey: Self.enabledKey)
    }

    func enableBatteryMonitoringIfNeeded() {
        if self.previousBatteryMonitoringEnabled == nil {
            self.previousBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func restoreBatteryMonitoringIfNeeded() {
        guard let previousBatteryMonitoringEnabled else {
            return
        }
        UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoringEnabled
        self.previousBatteryMonitoringEnabled = nil
    }

    func startPhoneSampleLoop() {
        self.phoneSampleTask?.cancel()
        self.phoneSampleTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while self.enabled {
                let now = self.clock.now()
                do {
                    self.diagnostics.beginCoalescing()
                    defer {
                        self.diagnostics.endCoalescing()
                    }
                    self.refreshDiagnosticDecodeCounters(persist: true)
                    self.diagnostics.recordPhoneSample()
                    self.attributeOpenConnectedSilentGap(at: now)
                }
                self.refreshPendantReadings()
                self.refreshStorageBacklogReading()
                self.evaluateAudioRecovery(now: now)
                do {
                    try await self.clock.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    func stopPhoneSampleLoop() {
        self.phoneSampleTask?.cancel()
        self.phoneSampleTask = nil
    }

    func refreshPendantReadings() {
        self.readRSSI()

        let characteristic = self.characteristic(for: OmiUUIDs.batteryLevelCharacteristicID)
        let connectedPeripheral = self.currentConnectedPeripheral
        let connected = self.connectionState == .connected && connectedPeripheral?.state == .connected
        let hasCachedReadableCharacteristic = characteristic?.properties.contains(.read) == true
        guard self.isLaunchReady,
              !self.isOmiWorkDisabled,
              OmiSourceLogic.shouldReReadBattery(
            connected: connected,
            hasCachedReadableCharacteristic: hasCachedReadableCharacteristic
        ),
              let connectedPeripheral,
              let characteristic
        else {
            return
        }

        self.bluetoothPort.readValue(peripheralID: connectedPeripheral.id, characteristicID: characteristic.id)
    }

    func refreshStorageBacklogReading() {
        let characteristic = self.characteristic(for: OmiUUIDs.storageControlCharacteristicID)
        let connectedPeripheral = self.currentConnectedPeripheral
        guard self.isLaunchReady,
              !self.isOmiWorkDisabled,
              self.connectionState == .connected,
              let connectedPeripheral,
              connectedPeripheral.state == .connected,
              let characteristic,
              characteristic.properties.contains(.read)
        else {
            return
        }

        self.bluetoothPort.readValue(peripheralID: connectedPeripheral.id, characteristicID: characteristic.id)
    }

    func evaluateAudioRecovery(now: Date) {
        let health = OmiSourceLogic.audioHealth(
            connectionState: self.connectionState,
            lastAudioAt: self.lastAudioAt,
            connectedSince: self.diagnostics.payload.uptime.connectedSince,
            now: now
        )
        self.logAudioHealthTransition(health)

        if health == .receiving {
            self.silentEpisodeRecoveryFired = false
        }

        guard OmiSourceLogic.shouldAttemptResubscribe(
            health: health,
            isAudioSubscribed: self.isAudioSubscribed,
            alreadyFired: self.silentEpisodeRecoveryFired
        ) else {
            return
        }

        self.silentEpisodeRecoveryFired = true
        self.attemptAudioResubscribe()
    }

    func attemptAudioResubscribe() {
        guard self.isLaunchReady else { return }
        guard !self.isOmiWorkDisabled else { return }
        guard let characteristic = self.characteristic(for: OmiUUIDs.audioDataCharacteristicID) else {
            self.log.notice("omi audio recovery skipped: audio unavailable")
            return
        }

        self.log.notice("omi audio recovery: resubscribing")
        self.setAudioNotify(enabled: false, characteristic: characteristic)
        self.subscribeAudio()
    }

    func logAudioHealthTransition(_ health: OmiAudioHealth) {
        guard self.lastLoggedAudioHealth != health else {
            return
        }
        self.lastLoggedAudioHealth = health
        self.log.notice("omi audio health: \(self.audioHealthLogText(health), privacy: .public)")
    }

    func audioHealthLogText(_ health: OmiAudioHealth) -> String {
        switch health {
        case .receiving:
            return "receiving"
        case .silentWhileConnected:
            return "silent while connected"
        case .idle:
            return "idle"
        }
    }

    func cancelInitialConnectTimeout() {
        self.initialConnectTimeoutTask?.cancel()
        self.initialConnectTimeoutTask = nil
    }

    func markAbsentKnownFieldsUnavailable(for service: OmiServiceDescriptor, characteristics: [OmiCharacteristicDescriptor]) {
        if service.id.matches(OmiUUIDs.deviceInformationServiceID) {
            for characteristicID in [
                OmiUUIDs.firmwareRevisionCharacteristicID,
                OmiUUIDs.manufacturerNameCharacteristicID,
                OmiUUIDs.modelNumberCharacteristicID,
                OmiUUIDs.hardwareRevisionCharacteristicID
            ] where !self.containsCharacteristic(characteristicID, in: characteristics) {
                self.setStringField(characteristicID, state: .unavailable)
            }
        } else if service.id.matches(OmiUUIDs.batteryServiceID),
                  !self.containsCharacteristic(OmiUUIDs.batteryLevelCharacteristicID, in: characteristics)
        {
            self.battery = .unavailable
        } else if service.id.matches(OmiUUIDs.audioServiceID) {
            if !self.containsCharacteristic(OmiUUIDs.codecCharacteristicID, in: characteristics) {
                self.codec = .unavailable
            }
            if !self.containsCharacteristic(OmiUUIDs.audioDataCharacteristicID, in: characteristics) {
                self.connectionState = .needsAttention(.audioUnavailable)
                self.log.error("omi audio characteristic unavailable")
            }
        }
    }

    func containsCharacteristic(_ characteristicID: String, in characteristics: [OmiCharacteristicDescriptor]) -> Bool {
        characteristics.contains { $0.id.characteristicID.matches(characteristicID) }
    }

    func markKnownFieldUnavailable(for characteristicID: String) {
        if characteristicID.matches(OmiUUIDs.batteryLevelCharacteristicID) {
            self.battery = .unavailable
        } else if characteristicID.matches(OmiUUIDs.codecCharacteristicID) {
            self.codec = .unavailable
        } else if self.isDeviceInfoCharacteristic(characteristicID) {
            self.setStringField(characteristicID, state: .unavailable)
        }
    }

    func setStringField(_ characteristicID: String, state: OmiReadState<String>) {
        if characteristicID.matches(OmiUUIDs.firmwareRevisionCharacteristicID) {
            self.firmware = state
        } else if characteristicID.matches(OmiUUIDs.manufacturerNameCharacteristicID) {
            self.manufacturer = state
        } else if characteristicID.matches(OmiUUIDs.modelNumberCharacteristicID) {
            self.model = state
        } else if characteristicID.matches(OmiUUIDs.hardwareRevisionCharacteristicID) {
            self.hardwareRevision = state
        }
    }

    func isAutoReadCharacteristic(_ characteristicID: String) -> Bool {
        self.isDeviceInfoCharacteristic(characteristicID)
            || characteristicID.matches(OmiUUIDs.batteryLevelCharacteristicID)
            || characteristicID.matches(OmiUUIDs.codecCharacteristicID)
    }

    func isDeviceInfoCharacteristic(_ characteristicID: String) -> Bool {
        characteristicID.matches(OmiUUIDs.firmwareRevisionCharacteristicID)
            || characteristicID.matches(OmiUUIDs.manufacturerNameCharacteristicID)
            || characteristicID.matches(OmiUUIDs.modelNumberCharacteristicID)
            || characteristicID.matches(OmiUUIDs.hardwareRevisionCharacteristicID)
    }

    func characteristic(for characteristicID: String) -> OmiCharacteristicDescriptor? {
        self.characteristicsByID.values.first { $0.id.characteristicID.matches(characteristicID) }
    }

    func audioCharacteristic(in peripheral: OmiPeripheralDescriptor) -> OmiCharacteristicDescriptor? {
        peripheral.services
            .flatMap(\.characteristics)
            .first { $0.id.characteristicID.matches(OmiUUIDs.audioDataCharacteristicID) }
    }

    func cacheRestoredCharacteristics(in peripheral: OmiPeripheralDescriptor) {
        for service in peripheral.services {
            for characteristic in service.characteristics {
                self.characteristicsByID[characteristic.id] = characteristic
            }
        }
    }

    var currentAppStateString: String {
        OmiDiagnosticsLogic.appStateBucket(
            applicationStateIsActive: UIApplication.shared.applicationState == .active,
            isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
        )
    }

    var segmentConnectionState: String {
        OmiSourceLogic.segmentConnectionState(self.connectionState)
    }

    static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(Self.byte(data, offset: offset))
            | (UInt32(Self.byte(data, offset: offset + 1)) << 8)
            | (UInt32(Self.byte(data, offset: offset + 2)) << 16)
            | (UInt32(Self.byte(data, offset: offset + 3)) << 24)
    }

    static func byte(_ data: Data, offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func displayName(for id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

}

extension OmiSourceManager {
    func finalizeOpenChunkForBackground() async {
        guard self.isLaunchReady else { return }
        guard !self.isOmiWorkDisabled else { return }
        await self.omiSegmentWriter?.finalizeOpenChunk()
    }
}

private extension String {
    func matches(_ other: String) -> Bool {
        self.caseInsensitiveCompare(other) == .orderedSame
    }
}
