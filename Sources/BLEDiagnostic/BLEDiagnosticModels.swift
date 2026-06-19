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

nonisolated enum BLEPeripheralSource: Sendable, Equatable {
    case advertised
    case connectedSystem
}

nonisolated struct BLEDiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    var name: String?
    var rssi: Int
    var advertisedServiceUUIDs: [CBUUID]
    var source: BLEPeripheralSource
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

nonisolated struct BLEAudioCodecInfo: Equatable, Sendable {
    let rawByte: UInt8
    let label: String

    var isOpus: Bool {
        self.rawByte == 20 || self.rawByte == 21
    }
}

nonisolated enum BLEDrainState: Equatable, Sendable {
    case idle
    case listing
    case ready
    case reading
    case stopped
    case completed
    case failed(String)

    var displayString: String {
        switch self {
        case .idle:
            "idle"
        case .listing:
            "listing"
        case .ready:
            "ready"
        case .reading:
            "reading"
        case .stopped:
            "stopped"
        case .completed:
            "complete"
        case .failed(let reason):
            "failed: \(reason)"
        }
    }
}

nonisolated struct BLESDFileEntry: Identifiable, Equatable, Sendable {
    let id: UInt8
    let fileNumber: UInt8
    let sizeBytes: Int
    let savedOffset: Int
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
