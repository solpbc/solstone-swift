// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreBluetooth
import Foundation

nonisolated enum BLEReadState<Value: Equatable>: Equatable {
    case notRead
    case unavailable
    case value(Value)

    var placeholderText: String? {
        switch self {
        case .notRead:
            "not read yet"
        case .unavailable:
            "unavailable"
        case .value:
            nil
        }
    }
}

extension BLEReadState: Sendable where Value: Sendable {}

nonisolated enum BLELogSeverity: String, Sendable {
    case info
    case warn
    case error
}

nonisolated struct BLELogEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let severity: BLELogSeverity
    let message: String
    let hex: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: BLELogSeverity = .info,
        message: String,
        hex: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.message = message
        self.hex = hex
    }
}

nonisolated struct BLEDiscoveredPeripheral: Identifiable {
    let id: UUID
    var name: String?
    var rssi: Int
    var advertisedServiceUUIDs: [CBUUID]
}

nonisolated enum BLEConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case timedOut
    case failed(String)

    var displayString: String {
        switch self {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .timedOut:
            "connection timed out"
        case .failed(let reason):
            "connection failed: \(reason)"
        }
    }
}

nonisolated struct BLEServiceNode: Identifiable, Equatable, Sendable {
    let id: String
    let uuid: String
    let displayName: String
    var characteristics: [BLECharacteristicNode]
}

nonisolated struct BLECharacteristicNode: Identifiable, Equatable, Sendable {
    let id: String
    let uuid: String
    let displayName: String
    let propertyFlags: [String]
    let isReadable: Bool
    let isNotifiable: Bool
    var isNotifying: Bool
    var latestHex: String?
    var latestASCII: String?
}
