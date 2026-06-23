// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import CoreBluetooth
import Foundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class OmiSourceManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated static let restoreIdentifier = "app.solstone.swift.omi-source"
    private nonisolated static let enabledKey = "omiSource.enabled"
    private nonisolated static let lastConnectedPeripheralIDKey = "omiSource.lastConnectedPeripheralID"

    private nonisolated let log = Logger(subsystem: "app.solstone.swift", category: "omi")

    var enabled: Bool
    var managerState: CBManagerState = .unknown
    var connectionState: OmiSourceState = .disconnected
    var connectedPeripheralName: String?
    var connectedPeripheralID: String?
    var connectedRSSI: Int?
    var lastKnownBattery: TimedReading<Int>?
    var lastKnownSignal: TimedReading<Int>?
    var firmware: BLEReadState<String> = .notRead
    var manufacturer: BLEReadState<String> = .notRead
    var model: BLEReadState<String> = .notRead
    var hardwareRevision: BLEReadState<String> = .notRead
    var battery: BLEReadState<Int> = .notRead
    var codec: BLEReadState<BLEAudioCodecInfo> = .notRead
    var isAudioSubscribed = false
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
    let journalTally: OmiJournalTally

    @ObservationIgnored var onDecodedSamples: (@MainActor ([Int16]) -> Void)?
    @ObservationIgnored var omiSegmentWriter: OmiSegmentWriter?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristicsByID: [String: CBCharacteristic] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var reassembler = BLEAudioReassembler()
    @ObservationIgnored private var opusDecoder: BLEOpusAudioDecoder?
    @ObservationIgnored private var pendingConnectionID: UUID?
    @ObservationIgnored private var manuallyDisconnected = false
    @ObservationIgnored private var didLogPoweredOn = false
    @ObservationIgnored private var initialConnectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var wantsEnableOnPowerOn = false
    @ObservationIgnored private var phoneSampleTask: Task<Void, Never>?
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private var previousBatteryMonitoringEnabled: Bool?
    @ObservationIgnored private var silentEpisodeRecoveryFired = false
    @ObservationIgnored private(set) var didAttemptWriterStart = false
    @ObservationIgnored private var lastLoggedAudioHealth: OmiAudioHealth?

    init(
        defaults: UserDefaults = .standard,
        diagnostics: OmiDiagnostics = OmiDiagnostics(),
        journalTally: OmiJournalTally = OmiJournalTally(),
        clock: any ObserverClock = SystemObserverClock()
    ) {
        self.defaults = defaults
        self.diagnostics = diagnostics
        self.journalTally = journalTally
        self.clock = clock
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.lastKnownBattery = diagnostics.payload.pendantBatteryTrend.last.map {
            TimedReading(value: $0.level, at: $0.timestamp)
        }
        self.lastKnownSignal = nil
        super.init()
        self.central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
        )
    }

    func enable() {
        self.enabled = true
        self.persistEnabled(true)
        self.manuallyDisconnected = false
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

        let connected = self.central?.retrieveConnectedPeripherals(withServices: [
            BLEDiagnosticUUIDs.audioService,
            BLEDiagnosticUUIDs.storageService
        ]).first

        let persistedID = OmiSourceLogic.persistedPeripheralID(
            from: self.defaults.string(forKey: Self.lastConnectedPeripheralIDKey)
        )
        let persisted = persistedID.flatMap { id in
            self.central?.retrievePeripherals(withIdentifiers: [id]).first
        }

        guard let peripheral = connected ?? persisted else {
            self.connectionState = .needsAttention(.pendantNotFound)
            self.log.error("omi pendant not found")
            return
        }

        self.peripheralsByID[peripheral.identifier] = peripheral
        peripheral.delegate = self
        self.omiSegmentWriter?.start()
        self.beginConnect(peripheral, isReconnect: false)
    }

    func startSegmentWriterIfNeeded() {
        guard !self.didAttemptWriterStart else { return }
        self.didAttemptWriterStart = true
        self.omiSegmentWriter?.start()
    }

    func disable() {
        self.enabled = false
        self.persistEnabled(false)
        self.wantsEnableOnPowerOn = false
        self.stopPhoneSampleLoop()
        self.restoreBatteryMonitoringIfNeeded()
        self.manuallyDisconnected = true
        self.cancelInitialConnectTimeout()
        let pendingPeripheral = self.pendingConnectionID.flatMap { self.peripheralsByID[$0] }
        if let peripheral = self.connectedPeripheral ?? pendingPeripheral {
            self.central?.cancelPeripheralConnection(peripheral)
        }
        self.omiSegmentWriter?.stop()
        self.clearConnectionArtifacts()
        self.uptime.noteDisconnected(at: Date())
        self.connectionState = .disconnected
        self.log.info("omi stopped")
    }

    func resumeIfEnabled() async {
        guard self.defaults.bool(forKey: Self.enabledKey) else {
            self.enabled = false
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

    func handleWillRestoreState(restoredCount: Int) {
        self.log.info("omi restore received: \(restoredCount, privacy: .public) peripherals")
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            self.handleCentralStateUpdate(central.state)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let restoredCount = peripherals.count
        MainActor.assumeIsolated {
            self.handleWillRestoreState(restoredCount: restoredCount)
        }
        for peripheral in peripherals {
            MainActor.assumeIsolated {
                self.handleRestoredPeripheral(peripheral)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        MainActor.assumeIsolated {
            self.handleConnected(peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.handleFailedToConnect(peripheral, error: error)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.handleDisconnected(
                peripheral,
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
            self.handleDiscoveredServices(peripheral, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.handleDiscoveredCharacteristics(peripheral, service: service, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.handleUpdatedValue(peripheral, characteristic: characteristic, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.handleUpdatedNotificationState(characteristic, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.handleDidReadRSSI(peripheral, rssi: RSSI, error: error)
        }
    }
}

private extension OmiSourceManager {
    var restoreServiceUUIDs: [CBUUID] {
        [
            BLEDiagnosticUUIDs.audioService,
            BLEDiagnosticUUIDs.deviceInformationService,
            BLEDiagnosticUUIDs.batteryService,
            BLEDiagnosticUUIDs.storageService
        ]
    }

    func beginConnect(_ peripheral: CBPeripheral, isReconnect: Bool) {
        self.cancelInitialConnectTimeout()
        self.pendingConnectionID = peripheral.identifier
        self.peripheralsByID[peripheral.identifier] = peripheral
        peripheral.delegate = self
        self.connectionState = isReconnect ? .reconnecting : .connecting
        self.central?.connect(
            peripheral,
            options: [CBConnectPeripheralOptionEnableAutoReconnect: true]
        )
        self.log.info("omi \(isReconnect ? "reconnecting" : "connecting", privacy: .public)")

        guard !isReconnect else {
            return
        }

        let id = peripheral.identifier
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

    func handleCentralStateUpdate(_ state: CBManagerState) {
        self.managerState = state

        if state == .poweredOn {
            if !self.didLogPoweredOn {
                self.didLogPoweredOn = true
                self.log.info("omi bluetooth ready")
            }
            if !self.manuallyDisconnected,
               let pendingConnectionID,
               let peripheral = self.peripheralsByID[pendingConnectionID],
               self.connectedPeripheral == nil
            {
                self.beginConnect(peripheral, isReconnect: true)
            }
            if self.wantsEnableOnPowerOn,
               self.pendingConnectionID == nil,
               self.connectedPeripheral == nil
            {
                self.wantsEnableOnPowerOn = false
                self.enable()
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

    var isTryingOrConnected: Bool {
        if self.pendingConnectionID != nil || self.connectedPeripheral != nil {
            return true
        }
        switch self.connectionState {
        case .connecting, .connected, .reconnecting:
            return true
        case .disconnected, .needsAttention:
            return false
        }
    }

    func handleRestoredPeripheral(_ peripheral: CBPeripheral) {
        self.peripheralsByID[peripheral.identifier] = peripheral
        peripheral.delegate = self

        let audioCharacteristic = self.audioCharacteristic(in: peripheral)
        let hasAudioService = peripheral.services?.contains {
            uuidMatches($0.uuid, BLEDiagnosticUUIDs.audioService)
        } ?? false
        let action = OmiSourceLogic.restoreAction(
            peripheralState: peripheral.state,
            hasAudioService: hasAudioService,
            isAudioNotifying: audioCharacteristic?.isNotifying == true
        )

        self.log.info("omi restore action: \(String(describing: action), privacy: .public)")
        switch action {
        case .rearmConnect:
            self.beginConnect(peripheral, isReconnect: true)
        case .discoverServices:
            self.adoptConnectedPeripheral(peripheral)
            self.connectionState = .connected
            peripheral.discoverServices(self.restoreServiceUUIDs)
        case .subscribeAudio:
            self.adoptConnectedPeripheral(peripheral)
            self.connectionState = .connected
            if let audioCharacteristic {
                self.setAudioNotify(enabled: true, characteristic: audioCharacteristic)
            } else if let audioService = peripheral.services?.first(where: { uuidMatches($0.uuid, BLEDiagnosticUUIDs.audioService) }) {
                peripheral.discoverCharacteristics(nil, for: audioService)
            } else {
                self.connectionState = .needsAttention(.audioUnavailable)
                self.log.error("omi audio unavailable after restore")
            }
        case .alreadyLive:
            self.adoptConnectedPeripheral(peripheral)
            self.connectionState = .connected
            self.isAudioSubscribed = true
            if self.opusDecoder == nil {
                self.buildOpusDecoder()
            }
        }
    }

    func handleConnected(_ peripheral: CBPeripheral) {
        self.cancelInitialConnectTimeout()
        self.pendingConnectionID = nil
        self.adoptConnectedPeripheral(peripheral)

        if let reconnectStartedAt {
            let latency = Date().timeIntervalSince(reconnectStartedAt)
            self.lastReconnectLatencySeconds = latency
            self.reconnectCount += 1
            self.eventRing.backfillMostRecentReconnect(timeToReconnect: latency)
            self.diagnostics.recordReconnect(latency: latency)
            self.reconnectStartedAt = nil
            self.isSystemReconnecting = false
        }

        self.connectionState = .connected
        self.diagnostics.recordConnected()
        self.uptime.noteConnected(at: Date())
        self.connectedRSSI = nil
        self.lastAudioAt = nil
        self.silentEpisodeRecoveryFired = false
        self.lastLoggedAudioHealth = nil
        self.resetReadState()
        self.clearAudioState()
        self.characteristicsByID.removeAll()
        self.readRSSI()
        self.log.info("omi connected")
        peripheral.discoverServices(nil)
    }

    func handleFailedToConnect(_ peripheral: CBPeripheral, error: (any Error)?) {
        self.cancelInitialConnectTimeout()
        self.pendingConnectionID = nil
        let reason = error?.localizedDescription ?? "unknown error"
        self.connectionState = .needsAttention(.connectFailed(reason))
        self.clearConnectionArtifacts()
        self.log.error("omi connection failed: \(reason, privacy: .public)")
    }

    func handleDisconnected(
        _ peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        let disconnectedAt = Date(timeIntervalSinceReferenceDate: timestamp)
        self.lastDisconnectedAt = disconnectedAt
        self.uptime.noteDisconnected(at: disconnectedAt)

        let decision = OmiSourceLogic.reconnectDecision(
            isManualDisconnect: self.manuallyDisconnected,
            isReconnecting: isReconnecting
        )

        if !self.manuallyDisconnected {
            let event = OmiSourceEvent(
                timestamp: disconnectedAt,
                reason: error?.localizedDescription ?? "link lost",
                appStateAtDrop: self.currentAppStateString,
                timeToReconnect: nil
            )
            self.eventRing.append(event)
            self.diagnostics.recordDisconnected(event: event)
        }

        switch decision {
        case .stayDisconnected:
            self.connectionState = .disconnected
            self.clearConnectionArtifacts()
            self.log.info("omi stopped")
        case .systemReconnecting:
            self.isSystemReconnecting = true
            self.reconnectStartedAt = disconnectedAt
            self.connectionState = .reconnecting
            self.clearTransientConnectionState()
            self.log.info("omi reconnecting through bluetooth")
        case .rearmConnect:
            self.isSystemReconnecting = false
            self.reconnectStartedAt = disconnectedAt
            self.connectionState = .reconnecting
            self.clearTransientConnectionState()
            self.beginConnect(peripheral, isReconnect: true)
            self.log.info("omi reconnect armed")
        }
    }

    func handleDiscoveredServices(_ peripheral: CBPeripheral, error: (any Error)?) {
        if let error {
            self.connectionState = .needsAttention(.connectFailed(error.localizedDescription))
            self.log.error("omi profile discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let services = peripheral.services ?? []
        self.log.info("omi profiles discovered: \(services.count, privacy: .public)")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func handleDiscoveredCharacteristics(
        _ peripheral: CBPeripheral,
        service: CBService,
        error: (any Error)?
    ) {
        if let error {
            self.log.error("omi characteristic discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            self.characteristicsByID[self.characteristicID(characteristic)] = characteristic
        }

        self.markAbsentKnownFieldsUnavailable(for: service, characteristics: characteristics)
        self.log.info("omi characteristics discovered: \(characteristics.count, privacy: .public)")

        for characteristic in characteristics where characteristic.properties.contains(.read) {
            if self.isAutoReadCharacteristic(characteristic.uuid) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func handleUpdatedValue(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if uuidMatches(characteristic.uuid, BLEDiagnosticUUIDs.audioDataCharacteristic) {
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

        if let error {
            self.markKnownFieldUnavailable(for: characteristic.uuid)
            self.log.error("omi value read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let data = characteristic.value, !data.isEmpty else {
            self.markKnownFieldUnavailable(for: characteristic.uuid)
            self.log.error("omi value empty")
            return
        }

        if self.updateKnownField(characteristic.uuid, data: data) {
            return
        }
    }

    func handleUpdatedNotificationState(
        _ characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard uuidMatches(characteristic.uuid, BLEDiagnosticUUIDs.audioDataCharacteristic) else {
            return
        }

        if let error {
            self.connectionState = .needsAttention(.audioUnavailable)
            self.log.error("omi audio notify failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        if characteristic.isNotifying {
            self.isAudioSubscribed = true
            self.resetAudioLiveState()
            self.buildOpusDecoder()
            self.log.info("omi audio stream enabled")
        } else {
            self.isAudioSubscribed = false
            self.opusDecoder = nil
            self.log.info("omi audio stream disabled")
        }
    }

    func handleDidReadRSSI(
        _ peripheral: CBPeripheral,
        rssi RSSI: NSNumber,
        error: (any Error)?
    ) {
        if let error {
            self.log.info("omi rssi read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let level = RSSI.intValue
        let now = Date()
        self.connectedRSSI = level
        self.lastKnownSignal = TimedReading(value: level, at: now)
        self.diagnostics.recordSignal(level: level, at: now)
    }

    func handleAudioData(_ data: Data) {
        let output = self.reassembler.ingest(data)

        for marker in output.markers {
            self.lastMarkerDate = Date(timeIntervalSince1970: Double(marker.epoch))
            self.log.info("omi audio marker: \(marker.epoch, privacy: .public)")
        }

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
        self.diagnostics.updateDecodeCounters(
            ok: self.audioDecodeOK,
            errors: self.audioDecodeErrors,
            gaps: self.audioGaps,
            outOfOrder: self.audioOutOfOrder
        )
        if deltas.decodeOK > 0 {
            self.startSegmentWriterIfNeeded()
            let now = Date()
            self.lastAudioAt = now
            self.diagnostics.noteDecodedSamples(at: now)
            self.evaluateAudioRecovery(now: now)
        }
    }

    func updateKnownField(_ uuid: CBUUID, data: Data) -> Bool {
        if uuidMatches(uuid, BLEDiagnosticUUIDs.batteryLevelCharacteristic) {
            let level = Int(data[0])
            let now = Date()
            self.battery = .value(level)
            self.lastKnownBattery = TimedReading(value: level, at: now)
            self.diagnostics.recordBattery(level: level, at: now)
            self.log.info("omi battery read")
            return true
        }

        if uuidMatches(uuid, BLEDiagnosticUUIDs.codecCharacteristic) {
            guard let byte = data.first else {
                self.codec = .unavailable
                self.log.error("omi codec unavailable")
                return true
            }
            let info = BLEAudioCodecInfo(
                rawByte: byte,
                label: BLEDiagnosticFormatters.codecLabel(byte)
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
            self.markKnownFieldUnavailable(for: uuid)
            return self.isDeviceInfoCharacteristic(uuid)
        }

        if self.isDeviceInfoCharacteristic(uuid) {
            self.setStringField(uuid, state: .value(text))
            self.log.info("omi device info read")
            return true
        }

        return false
    }

    func subscribeAudio() {
        self.didAttemptWriterStart = false
        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.audioDataCharacteristic) else {
            self.connectionState = .needsAttention(.audioUnavailable)
            self.log.error("omi audio unavailable")
            return
        }
        self.setAudioNotify(enabled: true, characteristic: characteristic)
    }

    func setAudioNotify(enabled: Bool, characteristic: CBCharacteristic) {
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            self.connectionState = .needsAttention(.audioUnavailable)
            self.log.error("omi audio notify unavailable")
            return
        }
        self.connectedPeripheral?.setNotifyValue(enabled, for: characteristic)
    }

    func buildOpusDecoder() {
        do {
            self.opusDecoder = try BLEOpusAudioDecoder()
        } catch {
            self.opusDecoder = nil
            self.log.error("omi opus decoder unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func readRSSI() {
        guard self.connectionState == .connected,
              let connectedPeripheral
        else {
            return
        }
        connectedPeripheral.readRSSI()
    }

    func adoptConnectedPeripheral(_ peripheral: CBPeripheral) {
        self.connectedPeripheral = peripheral
        self.connectedPeripheralName = peripheral.name ?? self.displayName(for: peripheral.identifier)
        self.connectedPeripheralID = peripheral.identifier.uuidString
        self.peripheralsByID[peripheral.identifier] = peripheral
        self.defaults.set(
            OmiSourceLogic.storedPeripheralIDValue(for: peripheral.identifier),
            forKey: Self.lastConnectedPeripheralIDKey
        )
        peripheral.delegate = self
    }

    func clearConnectionArtifacts() {
        self.connectedRSSI = nil
        self.connectedPeripheral = nil
        self.connectedPeripheralName = nil
        self.connectedPeripheralID = nil
        self.characteristicsByID.removeAll()
        self.pendingConnectionID = nil
        self.reconnectStartedAt = nil
        self.isSystemReconnecting = false
        self.silentEpisodeRecoveryFired = false
        self.didAttemptWriterStart = false
        self.lastLoggedAudioHealth = nil
        self.resetReadState()
        self.clearAudioState()
    }

    func clearTransientConnectionState() {
        self.connectedRSSI = nil
        self.characteristicsByID.removeAll()
        self.isAudioSubscribed = false
        self.opusDecoder = nil
        self.silentEpisodeRecoveryFired = false
        self.didAttemptWriterStart = false
        self.lastLoggedAudioHealth = nil
    }

    func clearAudioState() {
        self.isAudioSubscribed = false
        self.opusDecoder = nil
        self.resetAudioLiveState()
    }

    func resetAudioLiveState() {
        self.reassembler = BLEAudioReassembler()
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
                self.diagnostics.recordPhoneSample()
                self.refreshPendantReadings()
                self.evaluateAudioRecovery(now: self.clock.now())
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

        let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.batteryLevelCharacteristic)
        let connected = self.connectionState == .connected && self.connectedPeripheral != nil
        let hasCachedReadableCharacteristic = characteristic?.properties.contains(.read) == true
        guard OmiSourceLogic.shouldReReadBattery(
            connected: connected,
            hasCachedReadableCharacteristic: hasCachedReadableCharacteristic
        ),
              let connectedPeripheral,
              let characteristic
        else {
            return
        }

        connectedPeripheral.readValue(for: characteristic)
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
        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.audioDataCharacteristic) else {
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

    func markAbsentKnownFieldsUnavailable(for service: CBService, characteristics: [CBCharacteristic]) {
        if uuidMatches(service.uuid, BLEDiagnosticUUIDs.deviceInformationService) {
            for uuid in [
                BLEDiagnosticUUIDs.firmwareRevisionCharacteristic,
                BLEDiagnosticUUIDs.manufacturerNameCharacteristic,
                BLEDiagnosticUUIDs.modelNumberCharacteristic,
                BLEDiagnosticUUIDs.hardwareRevisionCharacteristic
            ] where !self.containsCharacteristic(uuid, in: characteristics) {
                self.setStringField(uuid, state: .unavailable)
            }
        } else if uuidMatches(service.uuid, BLEDiagnosticUUIDs.batteryService),
                  !self.containsCharacteristic(BLEDiagnosticUUIDs.batteryLevelCharacteristic, in: characteristics)
        {
            self.battery = .unavailable
        } else if uuidMatches(service.uuid, BLEDiagnosticUUIDs.audioService) {
            if !self.containsCharacteristic(BLEDiagnosticUUIDs.codecCharacteristic, in: characteristics) {
                self.codec = .unavailable
            }
            if !self.containsCharacteristic(BLEDiagnosticUUIDs.audioDataCharacteristic, in: characteristics) {
                self.connectionState = .needsAttention(.audioUnavailable)
                self.log.error("omi audio characteristic unavailable")
            }
        }
    }

    func containsCharacteristic(_ uuid: CBUUID, in characteristics: [CBCharacteristic]) -> Bool {
        characteristics.contains { uuidMatches($0.uuid, uuid) }
    }

    func markKnownFieldUnavailable(for uuid: CBUUID) {
        if uuidMatches(uuid, BLEDiagnosticUUIDs.batteryLevelCharacteristic) {
            self.battery = .unavailable
        } else if uuidMatches(uuid, BLEDiagnosticUUIDs.codecCharacteristic) {
            self.codec = .unavailable
        } else if self.isDeviceInfoCharacteristic(uuid) {
            self.setStringField(uuid, state: .unavailable)
        }
    }

    func setStringField(_ uuid: CBUUID, state: BLEReadState<String>) {
        if uuidMatches(uuid, BLEDiagnosticUUIDs.firmwareRevisionCharacteristic) {
            self.firmware = state
        } else if uuidMatches(uuid, BLEDiagnosticUUIDs.manufacturerNameCharacteristic) {
            self.manufacturer = state
        } else if uuidMatches(uuid, BLEDiagnosticUUIDs.modelNumberCharacteristic) {
            self.model = state
        } else if uuidMatches(uuid, BLEDiagnosticUUIDs.hardwareRevisionCharacteristic) {
            self.hardwareRevision = state
        }
    }

    func isAutoReadCharacteristic(_ uuid: CBUUID) -> Bool {
        self.isDeviceInfoCharacteristic(uuid)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.batteryLevelCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.codecCharacteristic)
    }

    func isDeviceInfoCharacteristic(_ uuid: CBUUID) -> Bool {
        uuidMatches(uuid, BLEDiagnosticUUIDs.firmwareRevisionCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.manufacturerNameCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.modelNumberCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.hardwareRevisionCharacteristic)
    }

    func characteristic(for uuid: CBUUID) -> CBCharacteristic? {
        self.characteristicsByID.values.first { uuidMatches($0.uuid, uuid) }
    }

    func characteristicID(_ characteristic: CBCharacteristic) -> String {
        if let service = characteristic.service {
            return "\(service.uuid.uuidString)|\(characteristic.uuid.uuidString)"
        }
        return characteristic.uuid.uuidString
    }

    func audioCharacteristic(in peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?
            .flatMap { $0.characteristics ?? [] }
            .first { uuidMatches($0.uuid, BLEDiagnosticUUIDs.audioDataCharacteristic) }
    }

    var currentAppStateString: String {
        switch UIApplication.shared.applicationState {
        case .active:
            "foreground"
        case .background:
            "background"
        case .inactive:
            "inactive"
        @unknown default:
            "inactive"
        }
    }

    func displayName(for id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}

private func uuidMatches(_ lhs: CBUUID, _ rhs: CBUUID) -> Bool {
    lhs.uuidString.caseInsensitiveCompare(rhs.uuidString) == .orderedSame
}
