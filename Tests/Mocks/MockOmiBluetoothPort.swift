// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class MockOmiBluetoothPort: OmiBluetoothPort {
    private(set) var startCallCount = 0
    var peripheralsByID: [UUID: OmiPeripheralDescriptor] = [:]
    var connectCalls: [(UUID, Bool)] = []
    var cancelCalls: [UUID] = []
    var discoverServicesCalls: [(UUID, [String]?)] = []
    var discoverCharacteristicsCalls: [(UUID, String)] = []
    var readValueCalls: [(UUID, OmiCharacteristicID)] = []
    var readRSSICalls: [UUID] = []
    var setNotifyCalls: [(UUID, OmiCharacteristicID, Bool)] = []

    var connectCallCount: Int { self.connectCalls.count }
    var cancelConnectionCallCount: Int { self.cancelCalls.count }
    var discoverServicesCallCount: Int { self.discoverServicesCalls.count }
    var discoverCharacteristicsCallCount: Int { self.discoverCharacteristicsCalls.count }
    var readValueCallCount: Int { self.readValueCalls.count }
    var readRSSICallCount: Int { self.readRSSICalls.count }
    var setNotifyCallCount: Int { self.setNotifyCalls.count }

    func start(delegate: any CBCentralManagerDelegate & CBPeripheralDelegate) { self.startCallCount += 1 }

    func register(_ peripheral: CBPeripheral) -> OmiPeripheralDescriptor {
        self.peripheralsByID[peripheral.identifier] ?? OmiPeripheralDescriptor(
            id: peripheral.identifier, name: peripheral.name, state: .disconnected, services: []
        )
    }

    func descriptor(peripheralID: UUID) -> OmiPeripheralDescriptor? { self.peripheralsByID[peripheralID] }

    func retrieveConnectedPeripherals(serviceIDs: [String]) -> [OmiPeripheralDescriptor] {
        self.peripheralsByID.values.filter { peripheral in
            peripheral.state == .connected && peripheral.services.contains { service in
                serviceIDs.contains { $0.caseInsensitiveCompare(service.id) == .orderedSame }
            }
        }
    }
    func retrievePeripherals(identifiers: [UUID]) -> [OmiPeripheralDescriptor] {
        identifiers.compactMap { self.peripheralsByID[$0] }
    }
    func connect(peripheralID: UUID, enablesAutoReconnect: Bool) { self.connectCalls.append((peripheralID, enablesAutoReconnect)) }
    func cancelConnection(peripheralID: UUID) { self.cancelCalls.append(peripheralID) }
    func discoverServices(peripheralID: UUID, serviceIDs: [String]?) { self.discoverServicesCalls.append((peripheralID, serviceIDs)) }
    func discoverCharacteristics(peripheralID: UUID, serviceID: String) { self.discoverCharacteristicsCalls.append((peripheralID, serviceID)) }
    func readValue(peripheralID: UUID, characteristicID: OmiCharacteristicID) { self.readValueCalls.append((peripheralID, characteristicID)) }
    func readRSSI(peripheralID: UUID) { self.readRSSICalls.append(peripheralID) }
    func setNotify(peripheralID: UUID, characteristicID: OmiCharacteristicID, enabled: Bool) { self.setNotifyCalls.append((peripheralID, characteristicID, enabled)) }

    func seed(_ descriptor: OmiPeripheralDescriptor) { self.peripheralsByID[descriptor.id] = descriptor }

    func setState(_ state: OmiPeripheralConnectionState, for peripheralID: UUID) {
        guard let descriptor = self.peripheralsByID[peripheralID] else { return }
        self.peripheralsByID[peripheralID] = OmiPeripheralDescriptor(
            id: descriptor.id,
            name: descriptor.name,
            state: state,
            services: descriptor.services,
            maximumWriteValueLength: descriptor.maximumWriteValueLength
        )
    }

    func setCharacteristic(_ characteristic: OmiCharacteristicDescriptor, for peripheralID: UUID) {
        guard let descriptor = self.peripheralsByID[peripheralID] else { return }
        let services = descriptor.services.map { service in
            guard service.id.caseInsensitiveCompare(characteristic.id.serviceID ?? "") == .orderedSame else { return service }
            return OmiServiceDescriptor(id: service.id, characteristics: service.characteristics.map { $0.id == characteristic.id ? characteristic : $0 })
        }
        self.peripheralsByID[peripheralID] = OmiPeripheralDescriptor(
            id: descriptor.id,
            name: descriptor.name,
            state: descriptor.state,
            services: services,
            maximumWriteValueLength: descriptor.maximumWriteValueLength
        )
    }

    func resetEffectHistory() {
        self.connectCalls.removeAll()
        self.cancelCalls.removeAll()
        self.discoverServicesCalls.removeAll()
        self.discoverCharacteristicsCalls.removeAll()
        self.readValueCalls.removeAll()
        self.readRSSICalls.removeAll()
        self.setNotifyCalls.removeAll()
    }
}
