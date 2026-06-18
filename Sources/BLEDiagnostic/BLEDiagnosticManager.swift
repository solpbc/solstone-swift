// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import CoreBluetooth
import Foundation
import Observation

@MainActor
@Observable
final class BLEDiagnosticManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated static let restoreIdentifier = "app.solstone.swift.ble-diagnostic"

    var managerState: CBManagerState = .unknown
    var isScanning = false
    var scanAllDevices = false
    var discovered: [BLEDiscoveredPeripheral] = []
    var connectionState: BLEConnectionState = .disconnected
    var connectedPeripheralName: String?
    var connectedPeripheralID: String?
    var services: [BLEServiceNode] = []
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
    var audioThroughputKBps = 0.0
    var audioLevel = 0.0
    var bufferedSeconds = 0.0
    var audioShareURL: URL?
    var sdDrainState: BLEDrainState = .idle
    var sdFiles: [BLESDFileEntry] = []
    var isStorageSubscribed = false
    var sdBytesReceived = 0
    var sdTotalBytes: Int?
    var sdProgress = 0.0
    var sdDrainThroughputKBps = 0.0
    var sdFramesSplit = 0
    var sdDecodeOK = 0
    var sdDecodeErrors = 0
    var sdMarkersSeen = 0
    var sdLastMarkerDate: Date?
    var sdRawShareURL: URL?
    var sdWavShareURL: URL?
    var sdDangerEnabled = false
    let log = BLEDiagnosticLog()

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var characteristicsByID: [String: CBCharacteristic] = [:]
    @ObservationIgnored private var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var sdStatsTask: Task<Void, Never>?
    @ObservationIgnored private var pendingConnectionID: UUID?
    @ObservationIgnored private var didLogPoweredOn = false
    @ObservationIgnored private var reassembler = BLEAudioReassembler()
    @ObservationIgnored private var sdReassembler = BLESDFileReassembler()
    @ObservationIgnored private var opusDecoder: BLEOpusAudioDecoder?
    @ObservationIgnored private var sdOpusDecoder: BLEOpusAudioDecoder?
    @ObservationIgnored private var pcmRing: [Int16] = []
    @ObservationIgnored private var sdRawBytes = Data()
    @ObservationIgnored private var sdPCMSamples: [Int16] = []
    @ObservationIgnored private var throughputWindow: [(timestamp: Date, bytes: Int)] = []
    @ObservationIgnored private var sdThroughputWindow: [(timestamp: Date, bytes: Int)] = []
    @ObservationIgnored private var didLogNonOpusSkip = false
    @ObservationIgnored private var sdReadOffset = 0
    @ObservationIgnored private var didFinishSDArtifacts = false

    private let pcmRingSampleLimit = 160_000
    private let throughputWindowSeconds: TimeInterval = 3

    var stateLine: String {
        BLEDiagnosticFormatters.stateLine(for: self.managerState)
    }

    var canSubscribeAudio: Bool {
        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.audioDataCharacteristic) else {
            return false
        }
        return characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
    }

    var hasStorageService: Bool {
        self.services.contains { service in
            uuidMatches(CBUUID(string: service.uuid), BLEDiagnosticUUIDs.storageService)
        } || self.characteristic(for: BLEDiagnosticUUIDs.storageDataCharacteristic) != nil
            || self.characteristic(for: BLEDiagnosticUUIDs.storageControlCharacteristic) != nil
    }

    var canReadStorageMetadata: Bool {
        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.storageControlCharacteristic) else {
            return false
        }
        return characteristic.properties.contains(.read)
    }

    var canSubscribeStorage: Bool {
        self.storageNotifyCandidate() != nil
    }

    override init() {
        super.init()
        // queue: nil -> delegate callbacks on main; MainActor.assumeIsolated bridges them with no actor-boundary crossing (CBPeripheral is non-Sendable).
        self.central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    func startScan() {
        guard self.managerState == .poweredOn else {
            self.log.append(severity: .warn, message: "scan unavailable: \(self.stateLine)")
            return
        }
        let services = self.scanAllDevices ? nil : BLEDiagnosticUUIDs.scanServiceUUIDs
        self.central?.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        self.isScanning = true
        self.log.append(message: self.scanAllDevices ? "scan started for all devices" : "scan started for audio service")
    }

    func stopScan() {
        self.central?.stopScan()
        self.isScanning = false
        self.log.append(message: "scan stopped")
    }

    func connect(_ id: UUID) {
        guard let peripheral = self.peripheralsByID[id] else {
            self.log.append(severity: .warn, message: "connect unavailable: peripheral missing")
            return
        }
        self.cancelConnectTimeout()
        self.pendingConnectionID = id
        self.connectionState = .connecting
        let name = peripheral.name ?? self.displayName(for: id)
        self.log.append(message: "connecting to \(name)")
        self.central?.connect(peripheral, options: nil)
        self.connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self,
                  !Task.isCancelled,
                  self.pendingConnectionID == id,
                  self.connectionState == .connecting,
                  let peripheral = self.peripheralsByID[id]
            else {
                return
            }
            self.connectionState = .timedOut
            self.log.append(severity: .error, message: "connection timed out")
            self.clearConnectionArtifacts()
            self.central?.cancelPeripheralConnection(peripheral)
        }
    }

    func disconnect() {
        self.cancelConnectTimeout()
        if let peripheral = self.connectedPeripheral {
            self.central?.cancelPeripheralConnection(peripheral)
        } else if let pendingConnectionID,
                  let peripheral = self.peripheralsByID[pendingConnectionID]
        {
            self.central?.cancelPeripheralConnection(peripheral)
        }
        self.pendingConnectionID = nil
        self.clearConnectionArtifacts()
        self.connectionState = .disconnected
        self.log.append(message: "disconnected")
    }

    func readDeviceInfo() {
        self.readStringField(
            uuid: BLEDiagnosticUUIDs.firmwareRevisionCharacteristic,
            fieldName: "firmware revision"
        )
        self.readStringField(
            uuid: BLEDiagnosticUUIDs.manufacturerNameCharacteristic,
            fieldName: "manufacturer"
        )
        self.readStringField(
            uuid: BLEDiagnosticUUIDs.modelNumberCharacteristic,
            fieldName: "model"
        )
        self.readStringField(
            uuid: BLEDiagnosticUUIDs.hardwareRevisionCharacteristic,
            fieldName: "hardware revision"
        )
    }

    func readBattery() {
        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.batteryLevelCharacteristic),
              characteristic.properties.contains(.read)
        else {
            self.battery = .unavailable
            self.log.append(severity: .warn, message: "battery unavailable")
            return
        }
        self.connectedPeripheral?.readValue(for: characteristic)
    }

    func readCodec() {
        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.codecCharacteristic),
              characteristic.properties.contains(.read)
        else {
            self.codec = .unavailable
            self.log.append(severity: .warn, message: "codec unavailable")
            return
        }
        self.connectedPeripheral?.readValue(for: characteristic)
    }

    func read(characteristic node: BLECharacteristicNode) {
        guard let characteristic = self.characteristicsByID[node.id],
              characteristic.properties.contains(.read)
        else {
            self.log.append(severity: .warn, message: "read unavailable for \(node.displayName)")
            return
        }
        self.connectedPeripheral?.readValue(for: characteristic)
    }

    func setNotify(_ node: BLECharacteristicNode, enabled: Bool) {
        guard let characteristic = self.characteristicsByID[node.id],
              node.isNotifiable
        else {
            self.log.append(severity: .warn, message: "notify unavailable for \(node.displayName)")
            return
        }
        self.connectedPeripheral?.setNotifyValue(enabled, for: characteristic)
    }

    func subscribeAudio() {
        self.setAudioNotify(enabled: true)
    }

    func unsubscribeAudio() {
        self.setAudioNotify(enabled: false)
    }

    func listStorageFiles() {
        guard let peripheral = self.connectedPeripheral else {
            self.log.append(severity: .warn, message: "sd-card list refused: not connected")
            return
        }

        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.storageControlCharacteristic),
              characteristic.properties.contains(.read)
        else {
            self.sdDrainState = .failed("metadata unavailable")
            self.log.append(severity: .warn, message: "sd-card metadata unavailable")
            return
        }

        self.sdDrainState = .listing
        self.log.append(message: "sd-card metadata read requested")
        peripheral.readValue(for: characteristic)
    }

    func readStorageFile(_ file: BLESDFileEntry, offset: Int = 0) {
        guard self.isStorageSubscribed else {
            self.log.append(severity: .warn, message: "sd-card read refused: notify disabled")
            return
        }

        let clampedOffset = max(0, min(offset, file.sizeBytes))
        self.resetSDDrainState()
        self.sdDrainState = .reading
        self.sdTotalBytes = file.sizeBytes > 0 ? file.sizeBytes : nil
        self.sdReadOffset = clampedOffset
        self.recomputeSDProgress()

        do {
            self.sdOpusDecoder = try BLEOpusAudioDecoder()
        } catch {
            self.sdDrainState = .failed("decoder unavailable")
            self.log.append(severity: .error, message: "sd-card decoder unavailable: \(error.localizedDescription)")
            return
        }

        let command = self.storageReadCommand(fileNumber: file.fileNumber, offset: clampedOffset)
        guard self.writeStorageCommand(command, actionName: "read file \(file.fileNumber)") else {
            self.sdDrainState = .failed("read command refused")
            self.sdOpusDecoder = nil
            return
        }

        self.startSDStatsTask()
    }

    func stopDrain() {
        let fileNumber = self.sdFiles.first?.fileNumber ?? 0x01
        let command = Data([0x03, fileNumber])
        if self.writeStorageCommand(command, actionName: "stop file \(fileNumber)") {
            self.sdDrainState = .stopped
            self.finishSDDrainArtifacts()
            self.log.append(message: "sd-card drain stopped")
        }
    }

    func deleteStorageFile(_ file: BLESDFileEntry) {
        guard self.sdDangerEnabled else {
            self.log.append(severity: .warn, message: "sd-card delete refused: danger controls disabled")
            return
        }

        let command = Data([0x01, file.fileNumber])
        if self.writeStorageCommand(command, actionName: "delete file \(file.fileNumber)") {
            self.log.append(message: "sd-card delete requested for file \(file.fileNumber)")
        }
    }

    func nukeStorage() {
        guard self.sdDangerEnabled else {
            self.log.append(severity: .warn, message: "sd-card erase refused: danger controls disabled")
            return
        }

        let command = Data([0x02, 0x01])
        if self.writeStorageCommand(command, actionName: "erase all") {
            self.log.append(message: "sd-card erase requested")
        }
    }

    func setStorageNotify(enabled: Bool) {
        guard let peripheral = self.connectedPeripheral else {
            self.log.append(severity: .warn, message: "sd-card notify refused: not connected")
            return
        }

        guard let characteristic = self.storageNotifyCharacteristic() else {
            return
        }

        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    func saveAudioWindow() {
        let samples = self.pcmRing
        guard !samples.isEmpty else {
            self.log.append(severity: .warn, message: "wav unavailable: no audio samples")
            return
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ble-audio.wav")
        do {
            let wav = BLEWavWriter.wavData(pcm16: samples)
            try wav.write(to: url, options: .atomic)
            self.audioShareURL = url
            self.log.append(message: "wrote wav: \(samples.count) samples")
        } catch {
            self.log.append(severity: .error, message: "wav write failed: \(error.localizedDescription)")
        }
    }

    func clearLog() {
        self.log.clear()
    }

    func logSnapshot() -> String {
        let firmwareValue: String?
        if case .value(let value) = self.firmware {
            firmwareValue = value
        } else {
            firmwareValue = nil
        }
        return self.log.logSnapshot(
            connectedPeripheralName: self.connectedPeripheralName,
            connectedPeripheralID: self.connectedPeripheralID,
            firmware: firmwareValue
        )
    }

    // L1 scaffolding only: constructed with the restore identifier and a willRestoreState handler. True state restoration also requires re-instantiating this manager at app launch (didFinishLaunching) with the same identifier; that is intentionally NOT wired in L1.
    func handleWillRestoreState(_ restoredCount: Int) {
        self.log.append(message: "restore state received: \(restoredCount) peripherals")
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
        let restoredCount = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.count ?? 0
        MainActor.assumeIsolated {
            self.handleWillRestoreState(restoredCount)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let advertisedServiceUUIDStrings = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            self.handleDiscovered(
                peripheral,
                advertisedName: advertisedName,
                advertisedServiceUUIDStrings: advertisedServiceUUIDStrings,
                rssi: rssi
            )
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
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.handleDisconnected(peripheral, error: error)
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

}

private extension BLEDiagnosticManager {
    func handleCentralStateUpdate(_ state: CBManagerState) {
        self.managerState = state
        if state != .poweredOn && self.isScanning {
            self.isScanning = false
        }
        if state == .poweredOn && !self.didLogPoweredOn {
            self.didLogPoweredOn = true
            self.log.append(message: "bluetooth on; no bonding prompt expected for diagnostic reads")
        }
    }

    func handleDiscovered(
        _ peripheral: CBPeripheral,
        advertisedName: String?,
        advertisedServiceUUIDStrings: [String],
        rssi: Int
    ) {
        let advertisedServices = advertisedServiceUUIDStrings.map(CBUUID.init(string:))
        self.peripheralsByID[peripheral.identifier] = peripheral
        let discoveredPeripheral = BLEDiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name ?? advertisedName,
            rssi: rssi,
            advertisedServiceUUIDs: advertisedServices
        )

        if let index = self.discovered.firstIndex(where: { $0.id == discoveredPeripheral.id }) {
            self.discovered[index] = discoveredPeripheral
        } else {
            self.discovered.append(discoveredPeripheral)
        }
    }

    func handleConnected(_ peripheral: CBPeripheral) {
        self.cancelConnectTimeout()
        self.pendingConnectionID = nil
        self.connectedPeripheral = peripheral
        self.connectedPeripheralName = peripheral.name ?? self.displayName(for: peripheral.identifier)
        self.connectedPeripheralID = peripheral.identifier.uuidString
        self.connectionState = .connected
        peripheral.delegate = self
        self.resetReadState()
        self.services = []
        self.characteristicsByID.removeAll()
        if self.isScanning {
            self.stopScan()
        }
        self.log.append(message: "connected to \(self.connectedPeripheralName ?? peripheral.identifier.uuidString)")
        peripheral.discoverServices(nil)
    }

    func handleFailedToConnect(_ peripheral: CBPeripheral, error: (any Error)?) {
        self.cancelConnectTimeout()
        self.pendingConnectionID = nil
        let reason = error?.localizedDescription ?? "unknown error"
        self.connectionState = .failed(reason)
        self.clearConnectionArtifacts()
        self.log.append(severity: .error, message: "connection failed: \(reason)")
    }

    func handleDisconnected(_ peripheral: CBPeripheral, error: (any Error)?) {
        self.cancelConnectTimeout()
        self.connectionState = .disconnected
        self.clearConnectionArtifacts()
        if let error {
            self.log.append(severity: .warn, message: "disconnected: \(error.localizedDescription)")
        } else {
            self.log.append(message: "disconnected")
        }
    }

    func handleDiscoveredServices(_ peripheral: CBPeripheral, error: (any Error)?) {
        if let error {
            self.log.append(severity: .error, message: "service discovery failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        self.services = services.map { service in
            BLEServiceNode(
                id: service.uuid.uuidString,
                uuid: service.uuid.uuidString,
                displayName: BLEDiagnosticUUIDs.displayName(for: service.uuid),
                characteristics: []
            )
        }
        self.log.append(message: "services discovered: \(services.count)")
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
            self.log.append(severity: .error, message: "characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        let nodes = characteristics.map { characteristic in
            let node = self.node(for: characteristic, service: service)
            self.characteristicsByID[node.id] = characteristic
            return node
        }
        if let serviceIndex = self.services.firstIndex(where: { $0.id == service.uuid.uuidString }) {
            self.services[serviceIndex].characteristics = nodes
        }
        self.log.append(message: "characteristics discovered for \(BLEDiagnosticUUIDs.displayName(for: service.uuid)): \(nodes.count)")
        self.markAbsentKnownFieldsUnavailable(for: service, characteristics: characteristics)

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
            if error == nil, let data = characteristic.value, !data.isEmpty {
                self.handleAudioData(data)
            }
            return
        }

        let id = self.characteristicID(characteristic)
        if self.isStorageCharacteristic(characteristic.uuid) {
            if let error {
                self.sdDrainState = .failed(error.localizedDescription)
                self.log.append(severity: .error, message: "sd-card value failed for \(BLEDiagnosticUUIDs.displayName(for: characteristic.uuid)): \(error.localizedDescription)")
                return
            }

            guard let data = characteristic.value, !data.isEmpty else {
                self.log.append(severity: .warn, message: "empty sd-card value for \(BLEDiagnosticUUIDs.displayName(for: characteristic.uuid))")
                return
            }

            let hex = BLEDiagnosticFormatters.hexDump(data)
            let ascii = BLEDiagnosticFormatters.asciiDump(data)
            self.updateCharacteristicValue(id: id, hex: hex, ascii: ascii)

            if uuidMatches(characteristic.uuid, BLEDiagnosticUUIDs.storageControlCharacteristic),
               data.count >= 8,
               self.sdDrainState == .listing
            {
                self.handleStorageMetadata(data)
            } else {
                self.handleStorageData(data)
            }
            return
        }

        if let error {
            self.markKnownFieldUnavailable(for: characteristic.uuid)
            self.log.append(severity: .error, message: "read failed for \(BLEDiagnosticUUIDs.displayName(for: characteristic.uuid)): \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value, !data.isEmpty else {
            self.markKnownFieldUnavailable(for: characteristic.uuid)
            self.log.append(severity: .warn, message: "empty value for \(BLEDiagnosticUUIDs.displayName(for: characteristic.uuid))")
            return
        }

        let hex = BLEDiagnosticFormatters.hexDump(data)
        let ascii = BLEDiagnosticFormatters.asciiDump(data)
        self.updateCharacteristicValue(id: id, hex: hex, ascii: ascii)

        if self.updateKnownField(characteristic.uuid, data: data) {
            return
        }

        self.log.append(
            message: "value updated for \(BLEDiagnosticUUIDs.displayName(for: characteristic.uuid)): \(ascii)",
            hex: hex
        )
    }

    func handleUpdatedNotificationState(
        _ characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        let id = self.characteristicID(characteristic)
        if let error {
            self.log.append(severity: .error, message: "notify update failed for \(BLEDiagnosticUUIDs.displayName(for: characteristic.uuid)): \(error.localizedDescription)")
            return
        }
        self.updateNotificationState(id: id, isNotifying: characteristic.isNotifying)
        if uuidMatches(characteristic.uuid, BLEDiagnosticUUIDs.audioDataCharacteristic) {
            self.handleAudioNotificationStateChanged(isNotifying: characteristic.isNotifying)
        } else if self.isStorageCharacteristic(characteristic.uuid) {
            self.handleStorageNotificationStateChanged(isNotifying: characteristic.isNotifying)
        }
        self.log.append(message: "\(characteristic.isNotifying ? "notify enabled" : "notify disabled") for \(BLEDiagnosticUUIDs.displayName(for: characteristic.uuid))")
    }

    func readStringField(uuid: CBUUID, fieldName: String) {
        guard let characteristic = self.characteristic(for: uuid),
              characteristic.properties.contains(.read)
        else {
            self.setStringField(uuid, state: .unavailable)
            self.log.append(severity: .warn, message: "\(fieldName) unavailable")
            return
        }
        self.connectedPeripheral?.readValue(for: characteristic)
    }

    func updateKnownField(_ uuid: CBUUID, data: Data) -> Bool {
        if uuidMatches(uuid, BLEDiagnosticUUIDs.batteryLevelCharacteristic) {
            self.battery = .value(Int(data[0]))
            self.log.append(message: "battery read: \(Int(data[0]))%")
            return true
        }

        if uuidMatches(uuid, BLEDiagnosticUUIDs.codecCharacteristic) {
            guard let byte = data.first else {
                self.codec = .unavailable
                self.log.append(severity: .warn, message: "codec unavailable")
                return true
            }
            let label = BLEDiagnosticFormatters.codecLabel(byte)
            self.codec = .value(BLEAudioCodecInfo(rawByte: byte, label: label))
            self.log.append(message: "codec read: \(label) (raw \(byte))")
            return true
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            self.markKnownFieldUnavailable(for: uuid)
            return self.isDeviceInfoCharacteristic(uuid)
        }

        if self.isDeviceInfoCharacteristic(uuid) {
            self.setStringField(uuid, state: .value(text))
            self.log.append(message: "\(BLEDiagnosticUUIDs.displayName(for: uuid)) read: \(text)")
            return true
        }

        return false
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

    func resetReadState() {
        self.firmware = .notRead
        self.manufacturer = .notRead
        self.model = .notRead
        self.hardwareRevision = .notRead
        self.battery = .notRead
        self.codec = .notRead
    }

    func cancelConnectTimeout() {
        self.connectTimeoutTask?.cancel()
        self.connectTimeoutTask = nil
    }

    func clearConnectionArtifacts() {
        self.connectedPeripheral = nil
        self.connectedPeripheralName = nil
        self.connectedPeripheralID = nil
        self.services = []
        self.characteristicsByID.removeAll()
        self.resetReadState()
        self.clearAudioState()
        self.clearSDDrainState()
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

    func node(for characteristic: CBCharacteristic, service: CBService) -> BLECharacteristicNode {
        let labels = BLEDiagnosticFormatters.propertyLabels(characteristic.properties)
        return BLECharacteristicNode(
            id: "\(service.uuid.uuidString)|\(characteristic.uuid.uuidString)",
            uuid: characteristic.uuid.uuidString,
            displayName: BLEDiagnosticUUIDs.displayName(for: characteristic.uuid),
            propertyFlags: labels,
            isReadable: characteristic.properties.contains(.read),
            isNotifiable: characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate),
            isNotifying: characteristic.isNotifying,
            latestHex: nil,
            latestASCII: nil
        )
    }

    func updateCharacteristicValue(id: String, hex: String, ascii: String) {
        for serviceIndex in self.services.indices {
            if let characteristicIndex = self.services[serviceIndex].characteristics.firstIndex(where: { $0.id == id }) {
                self.services[serviceIndex].characteristics[characteristicIndex].latestHex = hex
                self.services[serviceIndex].characteristics[characteristicIndex].latestASCII = ascii
                return
            }
        }
    }

    func updateNotificationState(id: String, isNotifying: Bool) {
        for serviceIndex in self.services.indices {
            if let characteristicIndex = self.services[serviceIndex].characteristics.firstIndex(where: { $0.id == id }) {
                self.services[serviceIndex].characteristics[characteristicIndex].isNotifying = isNotifying
                return
            }
        }
    }

    func isAutoReadCharacteristic(_ uuid: CBUUID) -> Bool {
        self.isDeviceInfoCharacteristic(uuid)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.batteryLevelCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.codecCharacteristic)
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
        }
    }

    func containsCharacteristic(_ uuid: CBUUID, in characteristics: [CBCharacteristic]) -> Bool {
        characteristics.contains { uuidMatches($0.uuid, uuid) }
    }

    func isDeviceInfoCharacteristic(_ uuid: CBUUID) -> Bool {
        uuidMatches(uuid, BLEDiagnosticUUIDs.firmwareRevisionCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.manufacturerNameCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.modelNumberCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.hardwareRevisionCharacteristic)
    }

    func handleAudioData(_ data: Data) {
        self.recordAudioThroughput(bytes: data.count)
        let output = self.reassembler.ingest(data)
        self.updateAudioCountersFromReassembler()

        for marker in output.markers {
            self.lastMarkerDate = Date(timeIntervalSince1970: Double(marker.epoch))
            self.log.append(
                message: "audio marker: epoch \(marker.epoch)",
                hex: BLEDiagnosticFormatters.hexDump(data)
            )
        }

        for frame in output.completedFrames {
            self.handleCompletedAudioFrame(frame)
        }
    }

    func handleCompletedAudioFrame(_ frame: Data) {
        guard case .value(let codec) = self.codec else {
            return
        }

        guard codec.isOpus else {
            if !self.didLogNonOpusSkip {
                self.didLogNonOpusSkip = true
                self.log.append(message: "live decode skipped: non-opus codec")
            }
            return
        }

        guard let opusDecoder,
              let samples = opusDecoder.decode(frame)
        else {
            self.audioDecodeErrors += 1
            return
        }

        self.audioDecodeOK += 1
        self.appendPCMSamples(samples)
        self.audioLevel = BLEDiagnosticFormatters.rmsLevel(pcm16: samples)
    }

    func handleAudioNotificationStateChanged(isNotifying: Bool) {
        if isNotifying {
            self.isAudioSubscribed = true
            self.resetAudioLiveState()
            do {
                self.opusDecoder = try BLEOpusAudioDecoder()
            } catch {
                self.opusDecoder = nil
                self.log.append(severity: .error, message: "opus decoder unavailable: \(error.localizedDescription)")
            }
            self.startAudioStatsTask()
        } else {
            self.isAudioSubscribed = false
            self.opusDecoder = nil
            self.cancelAudioStatsTask(appendFinal: true)
        }
    }

    func setAudioNotify(enabled: Bool) {
        guard let characteristic = self.characteristic(for: BLEDiagnosticUUIDs.audioDataCharacteristic),
              characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
        else {
            self.log.append(severity: .warn, message: "audio notify unavailable")
            return
        }
        self.connectedPeripheral?.setNotifyValue(enabled, for: characteristic)
    }

    func handleStorageNotificationStateChanged(isNotifying: Bool) {
        self.isStorageSubscribed = isNotifying
        if !isNotifying {
            self.sdOpusDecoder = nil
            self.cancelSDStatsTask(appendFinal: true)
        }
    }

    func storageNotifyCandidate() -> CBCharacteristic? {
        if let preferred = self.characteristic(for: BLEDiagnosticUUIDs.storageDataCharacteristic),
           self.isNotifiable(preferred)
        {
            return preferred
        }

        if let fallback = self.characteristic(for: BLEDiagnosticUUIDs.storageControlCharacteristic),
           self.isNotifiable(fallback)
        {
            return fallback
        }

        return nil
    }

    func storageNotifyCharacteristic() -> CBCharacteristic? {
        let preferred = self.characteristic(for: BLEDiagnosticUUIDs.storageDataCharacteristic)
        if let preferred, self.isNotifiable(preferred) {
            return preferred
        }

        let fallback = self.characteristic(for: BLEDiagnosticUUIDs.storageControlCharacteristic)
        if let fallback, self.isNotifiable(fallback) {
            self.log.append(severity: .warn, message: "sd-card notify role mismatch: using sd-card control")
            return fallback
        }

        if preferred != nil || fallback != nil {
            self.log.append(severity: .warn, message: "sd-card notify unavailable: characteristic lacks notify/indicate")
        } else {
            self.log.append(severity: .warn, message: "sd-card notify unavailable: characteristic missing")
        }
        return nil
    }

    func storageWriteCharacteristic(actionName: String) -> CBCharacteristic? {
        let preferred = self.characteristic(for: BLEDiagnosticUUIDs.storageControlCharacteristic)
        if let preferred, preferred.properties.contains(.write) {
            return preferred
        }

        let fallback = self.characteristic(for: BLEDiagnosticUUIDs.storageDataCharacteristic)
        if let fallback, fallback.properties.contains(.write) {
            self.log.append(severity: .warn, message: "sd-card write role mismatch: using sd-card data")
            return fallback
        }

        if preferred?.properties.contains(.writeWithoutResponse) == true
            || fallback?.properties.contains(.writeWithoutResponse) == true
        {
            self.log.append(severity: .warn, message: "sd-card \(actionName) refused: writeWithoutResponse only")
        } else if preferred != nil || fallback != nil {
            self.log.append(severity: .warn, message: "sd-card \(actionName) refused: characteristic lacks write")
        } else {
            self.log.append(severity: .warn, message: "sd-card \(actionName) refused: characteristic missing")
        }
        return nil
    }

    @discardableResult
    func writeStorageCommand(_ command: Data, actionName: String) -> Bool {
        guard let peripheral = self.connectedPeripheral else {
            self.log.append(severity: .warn, message: "sd-card \(actionName) refused: not connected")
            return false
        }

        guard let characteristic = self.storageWriteCharacteristic(actionName: actionName) else {
            return false
        }

        self.log.append(
            message: "sd-card command issued: \(actionName)",
            hex: BLEDiagnosticFormatters.hexDump(command)
        )
        peripheral.writeValue(command, for: characteristic, type: .withResponse)
        return true
    }

    func storageReadCommand(fileNumber: UInt8, offset: Int) -> Data {
        let boundedOffset = UInt32(max(0, min(offset, Int(UInt32.max))))
        return Data([
            0x00,
            fileNumber,
            UInt8((boundedOffset >> 24) & 0x000000FF),
            UInt8((boundedOffset >> 16) & 0x000000FF),
            UInt8((boundedOffset >> 8) & 0x000000FF),
            UInt8(boundedOffset & 0x000000FF)
        ])
    }

    func handleStorageMetadata(_ data: Data) {
        guard let totalBytes = self.readUInt32LE(data, offset: 0),
              let savedOffset = self.readUInt32LE(data, offset: 4)
        else {
            self.sdDrainState = .failed("metadata malformed")
            self.log.append(severity: .error, message: "sd-card metadata malformed", hex: BLEDiagnosticFormatters.hexDump(data))
            return
        }

        let fileSize = Int(totalBytes)
        let boundedSavedOffset = min(Int(savedOffset), fileSize)
        let file = BLESDFileEntry(
            id: 0x01,
            fileNumber: 0x01,
            sizeBytes: fileSize,
            savedOffset: boundedSavedOffset
        )
        self.sdFiles = [file]
        self.sdTotalBytes = fileSize > 0 ? fileSize : nil
        self.sdProgress = 0
        self.sdDrainState = .ready
        self.log.append(
            message: "sd-card metadata: files 1, size \(fileSize) bytes, saved offset \(boundedSavedOffset)",
            hex: BLEDiagnosticFormatters.hexDump(data)
        )
    }

    func handleStorageData(_ data: Data) {
        if self.handleStorageStatus(data) {
            return
        }

        self.sdRawBytes.append(data)
        self.sdBytesReceived += data.count
        self.recordSDThroughput(bytes: data.count)
        self.recomputeSDProgress()

        let output = self.sdReassembler.ingest(data)
        self.sdFramesSplit += output.completedFrames.count

        for marker in output.markers {
            self.sdMarkersSeen += 1
            self.sdLastMarkerDate = Date(timeIntervalSince1970: Double(marker.epoch))
            self.log.append(
                message: "sd-card marker: epoch \(marker.epoch)",
                hex: BLEDiagnosticFormatters.hexDump(data)
            )
        }

        for frame in output.completedFrames {
            self.handleCompletedSDFrame(frame)
        }

        let kbps = String(format: "%.1f", self.sdDrainThroughputKBps)
        self.log.append(
            message: "sd-card data: \(data.count) bytes, \(self.sdBytesReceived) total, \(kbps) kb/s",
            hex: BLEDiagnosticFormatters.hexDump(data)
        )

        if let total = self.sdTotalBytes,
           total > 0,
           self.sdReadOffset + self.sdBytesReceived >= total,
           self.sdDrainState == .reading
        {
            self.sdDrainState = .completed
            self.log.append(message: "sd-card drain complete by byte count")
            self.finishSDDrainArtifacts()
        }
    }

    func handleStorageStatus(_ data: Data) -> Bool {
        guard data.count == 1, let status = data.first else {
            return false
        }

        let hex = BLEDiagnosticFormatters.hexDump(data)
        switch status {
        case 0:
            self.log.append(message: "sd-card status: ok", hex: hex)
        case 100:
            self.sdDrainState = .completed
            self.log.append(message: "sd-card status: complete", hex: hex)
            self.finishSDDrainArtifacts()
        default:
            self.log.append(severity: .warn, message: "sd-card status: \(status)", hex: hex)
        }
        return true
    }

    func handleCompletedSDFrame(_ frame: Data) {
        guard let sdOpusDecoder,
              let samples = sdOpusDecoder.decode(frame)
        else {
            self.sdDecodeErrors += 1
            self.log.append(
                severity: .warn,
                message: "sd-card decode failed",
                hex: BLEDiagnosticFormatters.hexDump(frame)
            )
            return
        }

        self.sdDecodeOK += 1
        self.sdPCMSamples.append(contentsOf: samples)
    }

    func resetSDDrainState() {
        self.cancelSDStatsTask(appendFinal: false)
        self.sdReassembler = BLESDFileReassembler()
        self.sdOpusDecoder = nil
        self.sdRawBytes.removeAll(keepingCapacity: true)
        self.sdPCMSamples.removeAll(keepingCapacity: true)
        self.sdThroughputWindow.removeAll(keepingCapacity: true)
        self.sdReadOffset = 0
        self.didFinishSDArtifacts = false
        self.sdBytesReceived = 0
        self.sdTotalBytes = nil
        self.sdProgress = 0
        self.sdDrainThroughputKBps = 0
        self.sdFramesSplit = 0
        self.sdDecodeOK = 0
        self.sdDecodeErrors = 0
        self.sdMarkersSeen = 0
        self.sdLastMarkerDate = nil
        self.sdRawShareURL = nil
        self.sdWavShareURL = nil
        self.sdDrainState = .idle
    }

    func clearSDDrainState() {
        self.cancelSDStatsTask(appendFinal: false)
        self.isStorageSubscribed = false
        self.sdFiles = []
        self.sdDangerEnabled = false
        self.resetSDDrainState()
    }

    func recordSDThroughput(bytes: Int) {
        let now = Date()
        self.sdThroughputWindow.append((timestamp: now, bytes: bytes))
        self.recomputeSDThroughput(now: now)
    }

    func recomputeSDThroughput(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-self.throughputWindowSeconds)
        self.sdThroughputWindow.removeAll { $0.timestamp < cutoff }
        let bytes = self.sdThroughputWindow.reduce(0) { $0 + $1.bytes }
        guard let first = self.sdThroughputWindow.first else {
            self.sdDrainThroughputKBps = 0
            return
        }

        let elapsed = max(now.timeIntervalSince(first.timestamp), 0.1)
        self.sdDrainThroughputKBps = (Double(bytes) / 1_024.0) / elapsed
    }

    func startSDStatsTask() {
        self.cancelSDStatsTask(appendFinal: false)
        self.sdStatsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else {
                    return
                }
                self?.appendSDStatsSnapshot()
            }
        }
    }

    func cancelSDStatsTask(appendFinal: Bool) {
        self.sdStatsTask?.cancel()
        self.sdStatsTask = nil
        if appendFinal {
            self.appendSDStatsSnapshot()
        }
    }

    func appendSDStatsSnapshot() {
        self.recomputeSDThroughput()
        let kbps = String(format: "%.1f", self.sdDrainThroughputKBps)
        self.log.append(
            message: "sd-card: \(self.sdBytesReceived) bytes, \(self.sdFramesSplit) frames, \(self.sdDecodeOK) ok/\(self.sdDecodeErrors) err, markers \(self.sdMarkersSeen), \(kbps) kb/s"
        )
    }

    func finishSDDrainArtifacts() {
        guard !self.didFinishSDArtifacts else {
            return
        }
        self.didFinishSDArtifacts = true
        self.cancelSDStatsTask(appendFinal: true)
        self.sdOpusDecoder = nil

        let directory = FileManager.default.temporaryDirectory

        if !self.sdRawBytes.isEmpty {
            let rawURL = directory.appendingPathComponent("ble-sd-card-drain.opuspack")
            do {
                try self.sdRawBytes.write(to: rawURL, options: .atomic)
                self.sdRawShareURL = rawURL
                self.log.append(message: "sd-card raw ready: \(self.sdRawBytes.count) bytes")
            } catch {
                self.log.append(severity: .error, message: "sd-card raw write failed: \(error.localizedDescription)")
            }
        }

        if !self.sdPCMSamples.isEmpty {
            let wavURL = directory.appendingPathComponent("ble-sd-card-drain.wav")
            do {
                let wav = BLEWavWriter.wavData(pcm16: self.sdPCMSamples)
                try wav.write(to: wavURL, options: .atomic)
                self.sdWavShareURL = wavURL
                self.log.append(message: "sd-card wav ready: \(self.sdPCMSamples.count) samples")
            } catch {
                self.log.append(severity: .error, message: "sd-card wav write failed: \(error.localizedDescription)")
            }
        }
    }

    func recomputeSDProgress() {
        guard let total = self.sdTotalBytes, total > 0 else {
            self.sdProgress = 0
            return
        }

        let completedBytes = min(total, self.sdReadOffset + self.sdBytesReceived)
        self.sdProgress = Double(completedBytes) / Double(total)
    }

    func readUInt32LE(_ data: Data, offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else {
            return nil
        }

        let bytes = Array(data.dropFirst(offset).prefix(4))
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    func isStorageCharacteristic(_ uuid: CBUUID) -> Bool {
        uuidMatches(uuid, BLEDiagnosticUUIDs.storageDataCharacteristic)
            || uuidMatches(uuid, BLEDiagnosticUUIDs.storageControlCharacteristic)
    }

    func isNotifiable(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
    }

    func resetAudioLiveState() {
        self.reassembler = BLEAudioReassembler()
        self.pcmRing.removeAll(keepingCapacity: true)
        self.throughputWindow.removeAll(keepingCapacity: true)
        self.didLogNonOpusSkip = false
        self.audioPackets = 0
        self.audioFrames = 0
        self.audioDecodeOK = 0
        self.audioDecodeErrors = 0
        self.audioGaps = 0
        self.audioOutOfOrder = 0
        self.audioMalformed = 0
        self.audioMarkers = 0
        self.lastMarkerDate = nil
        self.audioThroughputKBps = 0
        self.audioLevel = 0
        self.bufferedSeconds = 0
        self.audioShareURL = nil
    }

    func clearAudioState() {
        self.cancelAudioStatsTask(appendFinal: false)
        self.opusDecoder = nil
        self.isAudioSubscribed = false
        self.resetAudioLiveState()
    }

    func updateAudioCountersFromReassembler() {
        self.audioPackets = self.reassembler.packets
        self.audioFrames = self.reassembler.frames
        self.audioGaps = self.reassembler.gaps
        self.audioOutOfOrder = self.reassembler.outOfOrder
        self.audioMalformed = self.reassembler.malformed
        self.audioMarkers = self.reassembler.markers
    }

    func appendPCMSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else {
            return
        }

        self.pcmRing.append(contentsOf: samples)
        if self.pcmRing.count > self.pcmRingSampleLimit {
            self.pcmRing.removeFirst(self.pcmRing.count - self.pcmRingSampleLimit)
        }
        self.bufferedSeconds = Double(self.pcmRing.count) / 16_000.0
    }

    func recordAudioThroughput(bytes: Int) {
        let now = Date()
        self.throughputWindow.append((timestamp: now, bytes: bytes))
        self.recomputeAudioThroughput(now: now)
    }

    func recomputeAudioThroughput(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-self.throughputWindowSeconds)
        self.throughputWindow.removeAll { $0.timestamp < cutoff }
        let bytes = self.throughputWindow.reduce(0) { $0 + $1.bytes }
        guard let first = self.throughputWindow.first else {
            self.audioThroughputKBps = 0
            return
        }

        let elapsed = max(now.timeIntervalSince(first.timestamp), 0.1)
        self.audioThroughputKBps = (Double(bytes) / 1_024.0) / elapsed
    }

    func startAudioStatsTask() {
        self.cancelAudioStatsTask(appendFinal: false)
        self.statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else {
                    return
                }
                self?.appendAudioStatsSnapshot()
            }
        }
    }

    func cancelAudioStatsTask(appendFinal: Bool) {
        self.statsTask?.cancel()
        self.statsTask = nil
        if appendFinal {
            self.appendAudioStatsSnapshot()
        }
    }

    func appendAudioStatsSnapshot() {
        self.recomputeAudioThroughput()
        let kbps = String(format: "%.1f", self.audioThroughputKBps)
        self.log.append(
            message: "audio: \(self.audioPackets) pkts, \(self.audioFrames) frames, \(self.audioDecodeOK) ok/\(self.audioDecodeErrors) err, gaps \(self.audioGaps), markers \(self.audioMarkers), \(kbps) kb/s"
        )
    }

    func displayName(for id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}

private func uuidMatches(_ lhs: CBUUID, _ rhs: CBUUID) -> Bool {
    lhs.uuidString.caseInsensitiveCompare(rhs.uuidString) == .orderedSame
}
