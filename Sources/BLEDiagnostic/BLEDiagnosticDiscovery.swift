// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreBluetooth
import Foundation

nonisolated enum BLEDiagnosticDiscovery {
    static func mergedDisplayList(
        advertised: [BLEDiscoveredPeripheral],
        connectedSystem: [BLEDiscoveredPeripheral],
        scanAllDevices: Bool
    ) -> [BLEDiscoveredPeripheral] {
        var advertisedByID: [UUID: BLEDiscoveredPeripheral] = [:]
        var connectedByID: [UUID: BLEDiscoveredPeripheral] = [:]

        for peripheral in advertised {
            advertisedByID[peripheral.id] = peripheral
        }
        for peripheral in connectedSystem {
            connectedByID[peripheral.id] = peripheral
        }

        let advertisedIDs = Set(advertisedByID.keys)
        let connectedIDs = Set(connectedByID.keys)
        let includedAdvertisedIDs = advertisedIDs.filter { id in
            guard let peripheral = advertisedByID[id] else {
                return false
            }
            return scanAllDevices || peripheral.advertisedServiceUUIDs.contains { uuid in
                uuid.uuidString.caseInsensitiveCompare(BLEDiagnosticUUIDs.audioService.uuidString) == .orderedSame
            }
        }
        let outputIDs = includedAdvertisedIDs.union(connectedIDs)

        return outputIDs.compactMap { id -> BLEDiscoveredPeripheral? in
            let advertised = advertisedByID[id]
            let connected = connectedByID[id]

            if let connected {
                return BLEDiscoveredPeripheral(
                    id: id,
                    name: Self.preferredName(advertised?.name, connected.name),
                    rssi: advertised?.rssi ?? connected.rssi,
                    advertisedServiceUUIDs: Self.preferredServices(
                        advertised?.advertisedServiceUUIDs,
                        connected.advertisedServiceUUIDs
                    ),
                    source: .connectedSystem
                )
            }

            return advertised
        }
        .sorted(by: Self.sortPeripheral(_:_:))
    }

    private static func preferredName(_ primary: String?, _ fallback: String?) -> String? {
        if let primary, !primary.isEmpty {
            return primary
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private static func preferredServices(_ primary: [CBUUID]?, _ fallback: [CBUUID]) -> [CBUUID] {
        if let primary, !primary.isEmpty {
            return primary
        }
        return fallback
    }

    private static func sortPeripheral(_ lhs: BLEDiscoveredPeripheral, _ rhs: BLEDiscoveredPeripheral) -> Bool {
        let lhsPriority = Self.sortPriority(for: lhs.source)
        let rhsPriority = Self.sortPriority(for: rhs.source)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsKey = Self.sortKey(for: lhs)
        let rhsKey = Self.sortKey(for: rhs)
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func sortPriority(for source: BLEPeripheralSource) -> Int {
        switch source {
        case .connectedSystem:
            0
        case .advertised:
            1
        }
    }

    private static func sortKey(for peripheral: BLEDiscoveredPeripheral) -> String {
        if let name = peripheral.name, !name.isEmpty {
            return name.lowercased()
        }
        return peripheral.id.uuidString.lowercased()
    }
}
