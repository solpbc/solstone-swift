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
    let log = BLEDiagnosticLog()

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var characteristicsByID: [String: CBCharacteristic] = [:]
    @ObservationIgnored private var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var pendingConnectionID: UUID?
    @ObservationIgnored private var didLogPoweredOn = false

    var stateLine: String {
        BLEDiagnosticFormatters.stateLine(for: self.managerState)
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
        let id = self.characteristicID(characteristic)
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
        self.isDeviceInfoCharacteristic(uuid) || uuidMatches(uuid, BLEDiagnosticUUIDs.batteryLevelCharacteristic)
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

    func displayName(for id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}

private func uuidMatches(_ lhs: CBUUID, _ rhs: CBUUID) -> Bool {
    lhs.uuidString.caseInsensitiveCompare(rhs.uuidString) == .orderedSame
}
