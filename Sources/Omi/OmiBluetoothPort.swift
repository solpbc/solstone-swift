// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import CoreBluetooth
import Foundation

nonisolated enum OmiPeripheralConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

nonisolated enum OmiBluetoothManagerState: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

nonisolated struct OmiCharacteristicProperties: OptionSet, Sendable, Equatable {
    let rawValue: UInt

    static let read = Self(rawValue: 1 << 0)
    static let notify = Self(rawValue: 1 << 1)
    static let indicate = Self(rawValue: 1 << 2)
}

nonisolated struct OmiCharacteristicID: Hashable, Sendable, Equatable {
    let serviceID: String?
    let characteristicID: String
}

nonisolated struct OmiCharacteristicDescriptor: Sendable, Equatable {
    let id: OmiCharacteristicID
    let properties: OmiCharacteristicProperties
    let isNotifying: Bool
    let value: Data?
}

nonisolated struct OmiServiceDescriptor: Sendable, Equatable {
    let id: String
    let characteristics: [OmiCharacteristicDescriptor]
}

nonisolated struct OmiPeripheralDescriptor: Sendable, Equatable {
    let id: UUID
    let name: String?
    let state: OmiPeripheralConnectionState
    let services: [OmiServiceDescriptor]
    let maximumWriteValueLength: Int?

    init(
        id: UUID,
        name: String?,
        state: OmiPeripheralConnectionState,
        services: [OmiServiceDescriptor],
        maximumWriteValueLength: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.services = services
        self.maximumWriteValueLength = maximumWriteValueLength
    }
}

@MainActor
protocol OmiBluetoothPort: AnyObject {
    func start(delegate: any CBCentralManagerDelegate & CBPeripheralDelegate)
    func register(_ peripheral: CBPeripheral) -> OmiPeripheralDescriptor
    func descriptor(peripheralID: UUID) -> OmiPeripheralDescriptor?
    func retrieveConnectedPeripherals(serviceIDs: [String]) -> [OmiPeripheralDescriptor]
    func retrievePeripherals(identifiers: [UUID]) -> [OmiPeripheralDescriptor]
    func connect(peripheralID: UUID, enablesAutoReconnect: Bool)
    func cancelConnection(peripheralID: UUID)
    func discoverServices(peripheralID: UUID, serviceIDs: [String]?)
    func discoverCharacteristics(peripheralID: UUID, serviceID: String)
    func readValue(peripheralID: UUID, characteristicID: OmiCharacteristicID)
    func readRSSI(peripheralID: UUID)
    func setNotify(peripheralID: UUID, characteristicID: OmiCharacteristicID, enabled: Bool) -> Bool
}

@MainActor
final class LiveOmiBluetoothPort: NSObject, OmiBluetoothPort {
    private var central: CBCentralManager?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private weak var peripheralDelegate: (any CBPeripheralDelegate)?

    func start(delegate: any CBCentralManagerDelegate & CBPeripheralDelegate) {
        self.peripheralDelegate = delegate
        self.central = CBCentralManager(
            delegate: delegate,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: OmiSourceManager.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
        )
    }

    func register(_ peripheral: CBPeripheral) -> OmiPeripheralDescriptor {
        self.peripheralsByID[peripheral.identifier] = peripheral
        peripheral.delegate = self.peripheralDelegate
        return Self.descriptor(for: peripheral)
    }

    func descriptor(peripheralID: UUID) -> OmiPeripheralDescriptor? {
        guard let peripheral = self.peripheralsByID[peripheralID] else { return nil }
        return Self.descriptor(for: peripheral)
    }

    func retrieveConnectedPeripherals(serviceIDs: [String]) -> [OmiPeripheralDescriptor] {
        let peripherals = self.central?.retrieveConnectedPeripherals(withServices: serviceIDs.map(CBUUID.init(string:))) ?? []
        return peripherals.map { self.register($0) }
    }

    func retrievePeripherals(identifiers: [UUID]) -> [OmiPeripheralDescriptor] {
        let peripherals = self.central?.retrievePeripherals(withIdentifiers: identifiers) ?? []
        return peripherals.map { self.register($0) }
    }

    func connect(peripheralID: UUID, enablesAutoReconnect: Bool) {
        guard let peripheral = self.peripheralsByID[peripheralID] else { return }
        self.central?.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: enablesAutoReconnect])
    }

    func cancelConnection(peripheralID: UUID) {
        guard let peripheral = self.peripheralsByID[peripheralID] else { return }
        self.central?.cancelPeripheralConnection(peripheral)
    }

    func discoverServices(peripheralID: UUID, serviceIDs: [String]?) {
        self.peripheralsByID[peripheralID]?.discoverServices(serviceIDs?.map(CBUUID.init(string:)))
    }

    func discoverCharacteristics(peripheralID: UUID, serviceID: String) {
        guard let peripheral = self.peripheralsByID[peripheralID],
              let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: serviceID) })
        else { return }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func readValue(peripheralID: UUID, characteristicID: OmiCharacteristicID) {
        guard let peripheral = self.peripheralsByID[peripheralID], let characteristic = Self.characteristic(characteristicID, in: peripheral) else { return }
        peripheral.readValue(for: characteristic)
    }

    func readRSSI(peripheralID: UUID) { self.peripheralsByID[peripheralID]?.readRSSI() }

    func setNotify(peripheralID: UUID, characteristicID: OmiCharacteristicID, enabled: Bool) -> Bool {
        guard let peripheral = self.peripheralsByID[peripheralID], let characteristic = Self.characteristic(characteristicID, in: peripheral) else { return false }
        peripheral.setNotifyValue(enabled, for: characteristic)
        return true
    }

    private static func characteristic(_ id: OmiCharacteristicID, in peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?.first(where: { service in
            id.serviceID == nil || service.uuid == CBUUID(string: id.serviceID ?? "")
        })?.characteristics?.first(where: { $0.uuid == CBUUID(string: id.characteristicID) })
    }

    nonisolated static func serviceDescriptor(for service: CBService) -> OmiServiceDescriptor {
        OmiServiceDescriptor(
            id: service.uuid.uuidString,
            characteristics: (service.characteristics ?? []).map(Self.makeCharacteristicDescriptor)
        )
    }

    nonisolated static func characteristicDescriptor(for characteristic: CBCharacteristic) -> OmiCharacteristicDescriptor {
        Self.makeCharacteristicDescriptor(characteristic)
    }

    nonisolated static func managerStateDescriptor(for state: CBManagerState) -> OmiBluetoothManagerState {
        switch state {
        case .resetting:
            .resetting
        case .unsupported:
            .unsupported
        case .unauthorized:
            .unauthorized
        case .poweredOff:
            .poweredOff
        case .poweredOn:
            .poweredOn
        default:
            .unknown
        }
    }

    nonisolated static func descriptor(for peripheral: CBPeripheral) -> OmiPeripheralDescriptor {
        let state: OmiPeripheralConnectionState
        switch peripheral.state {
        case .connected:
            state = .connected
        case .connecting:
            state = .connecting
        case .disconnecting:
            state = .disconnecting
        default:
            state = .disconnected
        }
        return OmiPeripheralDescriptor(
            id: peripheral.identifier,
            name: peripheral.name,
            state: state,
            services: (peripheral.services ?? []).map(Self.serviceDescriptor),
            maximumWriteValueLength: peripheral.maximumWriteValueLength(for: .withoutResponse)
        )
    }

    private nonisolated static func makeCharacteristicDescriptor(_ characteristic: CBCharacteristic) -> OmiCharacteristicDescriptor {
        var properties: OmiCharacteristicProperties = []
        if characteristic.properties.contains(.read) { properties.insert(.read) }
        if characteristic.properties.contains(.notify) { properties.insert(.notify) }
        if characteristic.properties.contains(.indicate) { properties.insert(.indicate) }
        return OmiCharacteristicDescriptor(
            id: OmiCharacteristicID(serviceID: characteristic.service?.uuid.uuidString, characteristicID: characteristic.uuid.uuidString),
            properties: properties,
            isNotifying: characteristic.isNotifying,
            value: characteristic.value
        )
    }
}
