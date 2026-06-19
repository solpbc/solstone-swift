// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import CoreBluetooth
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

nonisolated enum BLEDiagnosticStorage {
    static let cmdListFiles: UInt8 = 0x10
    static let cmdReadFile: UInt8 = 0x11
    static let cmdDeleteFile: UInt8 = 0x12
    static let cmdStopSync: UInt8 = 0x03
    static let storageFileListEntrySize = 8
    static let storageFileListMaxEntries = 50
    static let readTimeoutFailureReason = "no storage data received within 5s — read command likely wrong for this firmware"

    static func readCommandBytes(fileNumber: UInt8, offset: UInt32) -> [UInt8] {
        [
            Self.cmdReadFile,
            fileNumber,
            UInt8((offset >> 24) & 0x000000FF),
            UInt8((offset >> 16) & 0x000000FF),
            UInt8((offset >> 8) & 0x000000FF),
            UInt8(offset & 0x000000FF)
        ]
    }

    // Operator-confirmed on-device layout; the harness raw-logs responses for verification.
    static func parseFileList(_ data: Data) -> [BLESDFileEntry] {
        let entryCount = min(
            data.count / Self.storageFileListEntrySize,
            Self.storageFileListMaxEntries
        )
        guard entryCount > 0 else {
            return []
        }

        var entries: [BLESDFileEntry] = []
        entries.reserveCapacity(entryCount)
        for entryIndex in 0..<entryCount {
            let offset = entryIndex * Self.storageFileListEntrySize
            let indexBytes = Array(data.dropFirst(offset).prefix(4))
            let sizeBytes = Array(data.dropFirst(offset + 4).prefix(4))
            let fileIndex = UInt32(indexBytes[0])
                | (UInt32(indexBytes[1]) << 8)
                | (UInt32(indexBytes[2]) << 16)
                | (UInt32(indexBytes[3]) << 24)
            let fileSize = UInt32(sizeBytes[0])
                | (UInt32(sizeBytes[1]) << 8)
                | (UInt32(sizeBytes[2]) << 16)
                | (UInt32(sizeBytes[3]) << 24)
            let narrowedIndex = UInt8(truncatingIfNeeded: fileIndex)
            entries.append(BLESDFileEntry(
                id: narrowedIndex,
                fileNumber: narrowedIndex,
                sizeBytes: Int(fileSize),
                savedOffset: 0
            ))
        }
        return entries
    }

    static func parseFrame(_ data: Data) -> BLEStorageFrame {
        if data.count == 1, let status = data.first {
            return .status(status)
        }

        guard data.count >= 5 else {
            return .unexpected
        }

        let bytes = Array(data.prefix(4))
        let timestamp = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return .data(timestamp: timestamp, payload: Data(data.dropFirst(4)))
    }

    static func writeType(for properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        if properties.contains(.write) {
            return .withResponse
        }
        if properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        return nil
    }

    static func readTimeoutTransition(
        currentState: BLEDrainState,
        bytesReceived: Int
    ) -> BLEDrainState? {
        guard currentState == .reading, bytesReceived == 0 else {
            return nil
        }
        return .failed(Self.readTimeoutFailureReason)
    }
}

nonisolated enum BLEStorageStatus: Equatable, Sendable {
    case ok
    case invalidCommand
    case fileNotFound
    case fileIndexOutOfRange
    case storageNotReady
    case transferComplete
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 0:
            self = .ok
        case 6:
            self = .invalidCommand
        case 7:
            self = .fileNotFound
        case 8:
            self = .fileIndexOutOfRange
        case 9:
            self = .storageNotReady
        case 100:
            self = .transferComplete
        default:
            self = .unknown(rawValue)
        }
    }

    var label: String {
        switch self {
        case .ok:
            "OK"
        case .invalidCommand:
            "INVALID_COMMAND"
        case .fileNotFound:
            "FILE_NOT_FOUND"
        case .fileIndexOutOfRange:
            "FILE_INDEX_OUT_OF_RANGE"
        case .storageNotReady:
            "STORAGE_NOT_READY"
        case .transferComplete:
            "transfer complete"
        case .unknown(let rawValue):
            "status \(rawValue)"
        }
    }

    var isFailure: Bool {
        switch self {
        case .invalidCommand, .fileNotFound, .fileIndexOutOfRange, .storageNotReady:
            true
        case .ok, .transferComplete, .unknown:
            false
        }
    }
}

nonisolated enum BLEStorageFrame: Equatable, Sendable {
    case status(UInt8)
    case data(timestamp: UInt32, payload: Data)
    case unexpected
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
