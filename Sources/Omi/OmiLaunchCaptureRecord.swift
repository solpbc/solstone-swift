// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation

nonisolated enum OmiLaunchCaptureFormat {
    static let rootDirectoryName = "OmiLaunchCapture"
    static let quarantineDirectoryName = "Quarantine"
    static let fileExtension = "omilc"
    static let filePrefix = "launch-capture-"
    static let magic = Data("SOLLCAP1".utf8)
    static let version: UInt16 = 1
    static let maximumPayloadBytes = 512
    static let maximumResidentPayloadBytes = 1_024
    static let truncatedDigestByteCount = 16
    static let headerChecksumByteCount = truncatedDigestByteCount
    static let recordTagByteCount = truncatedDigestByteCount

    static let magicOffset = 0
    static let magicByteCount = magic.count
    static let versionOffset = magicOffset + magicByteCount
    static let versionByteCount = UInt16.bitWidth / 8
    static let generationIDOffset = versionOffset + versionByteCount
    static let generationIDByteCount = 16
    static let sequenceOffset = generationIDOffset + generationIDByteCount
    static let sequenceByteCount = UInt64.bitWidth / 8
    static let acquisitionTimeOffset = sequenceOffset + sequenceByteCount
    static let acquisitionTimeByteCount = Int64.bitWidth / 8
    static let declaredPayloadBytesOffset = acquisitionTimeOffset + acquisitionTimeByteCount
    static let declaredPayloadBytesByteCount = UInt16.bitWidth / 8
    static let headerChecksumOffset = declaredPayloadBytesOffset + declaredPayloadBytesByteCount
    static let headerByteCount = headerChecksumOffset + headerChecksumByteCount

    // Fixed scratch bounds: header encode/read = headerByteCount B, SHA-256 output =
    // sha256OutputByteCount B, and the reader body buffer = maximumPayloadBytes B payload
    // + recordTagByteCount B record tag.
    static let sha256OutputByteCount = 32
    static let readerBodyBufferByteCount = maximumPayloadBytes + recordTagByteCount

    static func fileURL(rootURL: URL, generationID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "\(Self.filePrefix)\(generationID.uuidString.lowercased()).\(Self.fileExtension)",
            isDirectory: false
        )
    }
}

nonisolated struct OmiLaunchCaptureRecord: Equatable, Sendable {
    let generationID: UUID
    let sequence: UInt64
    let acquiredAtUnixMicros: Int64
    let payload: Data
}

nonisolated enum OmiLaunchCaptureNotRetainedReason: String, Equatable, Sendable {
    case oversizeActualLength
    case openFailed
    case headerWriteFailed
    case reservationBarrierFailed
}

nonisolated enum OmiLaunchCaptureGapReason: String, Error, Equatable, Sendable {
    case payloadWriteFailed
    case recordTagWriteFailed
    case commitBarrierFailed
}

nonisolated enum OmiLaunchCaptureRejectionReason: Equatable, Sendable {
    case pendingSlotOccupied(pendingSequence: UInt64, retryFailure: OmiLaunchCaptureGapReason)
    case recoveryBoundary(reason: OmiLaunchCaptureBoundaryReason, offset: Int)
}

nonisolated enum OmiLaunchCaptureAppendOutcome: Equatable, Sendable {
    case retained(sequence: UInt64, retriedPending: Bool)
    case notRetained(OmiLaunchCaptureNotRetainedReason)
    case visibleGap(sequence: UInt64, OmiLaunchCaptureGapReason)
    case rejected(OmiLaunchCaptureRejectionReason)
}

nonisolated enum OmiLaunchCaptureBoundaryReason: String, Error, Equatable, Sendable {
    case incompleteHeader
    case preReservationCleanupFailed
    case invalidMagic
    case unsupportedVersion
    case generationMismatch
    case sequenceMismatch
    case headerChecksumMismatch
    case declaredLengthExceeded
    case incompleteReservedRecord
    case recordTagMismatch
    case readFailed
}

nonisolated enum OmiLaunchCaptureQuarantineDisposition: String, Equatable, Sendable {
    case notNeeded
    case moved
    case retainedInPlace
}

nonisolated struct OmiLaunchCaptureRecoveryResult: Equatable, Sendable {
    let verifiedRecords: [OmiLaunchCaptureRecord]
    /// Derived from the verified prefix length, never read from disk, and never a reservation claim.
    let verifiedPrefixNextSequence: UInt64
    /// Non-nil if and only if a checksum-valid durable reservation header exists at the boundary,
    /// which makes that boundary a visible gap.
    let boundarySequence: UInt64?
    let boundaryReason: OmiLaunchCaptureBoundaryReason?
    let boundaryOffset: Int?
    let quarantineDisposition: OmiLaunchCaptureQuarantineDisposition

    init(
        verifiedRecords: [OmiLaunchCaptureRecord],
        boundarySequence: UInt64? = nil,
        boundaryReason: OmiLaunchCaptureBoundaryReason? = nil,
        boundaryOffset: Int? = nil,
        quarantineDisposition: OmiLaunchCaptureQuarantineDisposition = .notNeeded
    ) {
        self.verifiedRecords = verifiedRecords
        self.verifiedPrefixNextSequence = UInt64(verifiedRecords.count)
        self.boundarySequence = boundarySequence
        self.boundaryReason = boundaryReason
        self.boundaryOffset = boundaryOffset
        self.quarantineDisposition = quarantineDisposition
    }

    func withQuarantineDisposition(_ disposition: OmiLaunchCaptureQuarantineDisposition) -> Self {
        Self(
            verifiedRecords: self.verifiedRecords,
            boundarySequence: self.boundarySequence,
            boundaryReason: self.boundaryReason,
            boundaryOffset: self.boundaryOffset,
            quarantineDisposition: disposition
        )
    }
}

nonisolated struct OmiLaunchCaptureHeader: Equatable, Sendable {
    let generationID: UUID
    let sequence: UInt64
    let acquiredAtUnixMicros: Int64
    let declaredPayloadBytes: Int

    func encoded() -> Data {
        var data = Data(capacity: OmiLaunchCaptureFormat.headerByteCount)
        precondition(data.count == OmiLaunchCaptureFormat.magicOffset)
        data.append(OmiLaunchCaptureFormat.magic)
        precondition(data.count == OmiLaunchCaptureFormat.versionOffset)
        data.appendLittleEndian(OmiLaunchCaptureFormat.version)
        precondition(data.count == OmiLaunchCaptureFormat.generationIDOffset)
        data.append(uuidBytes: self.generationID)
        precondition(data.count == OmiLaunchCaptureFormat.sequenceOffset)
        data.appendLittleEndian(self.sequence)
        precondition(data.count == OmiLaunchCaptureFormat.acquisitionTimeOffset)
        data.appendLittleEndian(self.acquiredAtUnixMicros)
        precondition(data.count == OmiLaunchCaptureFormat.declaredPayloadBytesOffset)
        data.appendLittleEndian(UInt16(self.declaredPayloadBytes))
        precondition(data.count == OmiLaunchCaptureFormat.headerChecksumOffset)
        data.append(OmiLaunchCaptureDigest.truncated(data))
        precondition(data.count == OmiLaunchCaptureFormat.headerByteCount)
        return data
    }

    static func decode(_ data: Data) -> Result<Self, OmiLaunchCaptureBoundaryReason> {
        guard data.count == OmiLaunchCaptureFormat.headerByteCount else {
            return .failure(.incompleteHeader)
        }
        guard data.prefix(OmiLaunchCaptureFormat.magicByteCount) == OmiLaunchCaptureFormat.magic else {
            return .failure(.invalidMagic)
        }
        guard data.uint16LE(at: OmiLaunchCaptureFormat.versionOffset) == OmiLaunchCaptureFormat.version else {
            return .failure(.unsupportedVersion)
        }
        guard OmiLaunchCaptureDigest.truncated(data.prefix(OmiLaunchCaptureFormat.headerChecksumOffset))
            == data.suffix(OmiLaunchCaptureFormat.headerChecksumByteCount)
        else {
            return .failure(.headerChecksumMismatch)
        }
        guard let generationID = data.uuid(at: OmiLaunchCaptureFormat.generationIDOffset) else {
            return .failure(.headerChecksumMismatch)
        }
        let declaredPayloadBytes = Int(data.uint16LE(at: OmiLaunchCaptureFormat.declaredPayloadBytesOffset))
        guard declaredPayloadBytes <= OmiLaunchCaptureFormat.maximumPayloadBytes else {
            return .failure(.declaredLengthExceeded)
        }
        return .success(Self(
            generationID: generationID,
            sequence: data.uint64LE(at: OmiLaunchCaptureFormat.sequenceOffset),
            acquiredAtUnixMicros: data.int64LE(at: OmiLaunchCaptureFormat.acquisitionTimeOffset),
            declaredPayloadBytes: declaredPayloadBytes
        ))
    }
}

nonisolated enum OmiLaunchCaptureDigest {
    static func truncated(_ data: some DataProtocol) -> Data {
        Data(SHA256.hash(data: data).prefix(OmiLaunchCaptureFormat.recordTagByteCount))
    }

    static func recordTag(header: Data, payload: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: header)
        hasher.update(data: payload)
        return Data(hasher.finalize().prefix(OmiLaunchCaptureFormat.recordTagByteCount))
    }
}

nonisolated extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        self.append(UInt8(value & 0x00FF))
        self.append(UInt8(value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        for offset in 0..<8 {
            self.append(UInt8((value >> UInt64(offset * 8)) & 0xFF))
        }
    }

    mutating func appendLittleEndian(_ value: Int64) {
        self.appendLittleEndian(UInt64(bitPattern: value))
    }

    mutating func append(uuidBytes value: UUID) {
        var uuid = value.uuid
        self.append(Swift.withUnsafeBytes(of: &uuid) { Data($0) })
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[self.startIndex + offset])
            | (UInt16(self[self.startIndex + offset + 1]) << 8)
    }

    func uint64LE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[self.startIndex + offset + index]) << UInt64(index * 8)
        }
        return value
    }

    func int64LE(at offset: Int) -> Int64 {
        Int64(bitPattern: self.uint64LE(at: offset))
    }

    func uuid(at offset: Int) -> UUID? {
        guard self.count >= offset + OmiLaunchCaptureFormat.generationIDByteCount else { return nil }
        let bytes = (0..<OmiLaunchCaptureFormat.generationIDByteCount).map { self[self.startIndex + offset + $0] }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
