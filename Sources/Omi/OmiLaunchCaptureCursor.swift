// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OmiLaunchCaptureCursorFormat {
    static let fileExtension = "cursor"
    static let magic = Data("solcursor1".utf8)
    static let version: UInt16 = 2
    static let versionByteCount = UInt16.bitWidth / 8
    static let sequenceByteCount = UInt64.bitWidth / 8
    static let offsetByteCount = UInt64.bitWidth / 8
    static let digestByteCount = OmiLaunchCaptureFormat.truncatedDigestByteCount
    static let byteCount = magic.count + versionByteCount
        + OmiLaunchCaptureFormat.generationIDByteCount
        + sequenceByteCount + offsetByteCount
        + sequenceByteCount + offsetByteCount
        + sequenceByteCount + sequenceByteCount + sequenceByteCount
        + digestByteCount

    static func fileURL(rootURL: URL, generationID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "\(OmiLaunchCaptureFormat.filePrefix)\(generationID.uuidString.lowercased()).\(fileExtension)",
            isDirectory: false
        )
    }
}

nonisolated enum OmiLaunchCaptureCursorDefectReason: String, Error, Equatable, Sendable {
    case invalidLength
    case invalidMagic
    case unsupportedVersion
    case cursorChecksumMismatch
    case generationMismatch
    case offsetOutOfRange
    case readFailed
}

nonisolated struct OmiLaunchCaptureCursorDefect: Equatable, Sendable {
    let reason: OmiLaunchCaptureCursorDefectReason
    let contentDigest: Data
}

nonisolated struct OmiLaunchCaptureCursor: Equatable, Sendable {
    let generationID: UUID
    let acknowledgedPrefixNextSequence: UInt64
    let acknowledgedPrefixEndOffset: Int
    let materializedPrefixNextSequence: UInt64
    let materializedPrefixEndOffset: Int
    let nextPartitionOrdinal: UInt64
    let nextSampleOffset: UInt64
    let replayMarkerNextSequence: UInt64

    init(
        generationID: UUID,
        acknowledgedPrefixNextSequence: UInt64,
        acknowledgedPrefixEndOffset: Int,
        materializedPrefixNextSequence: UInt64? = nil,
        materializedPrefixEndOffset: Int? = nil,
        nextPartitionOrdinal: UInt64 = 0,
        nextSampleOffset: UInt64 = 0,
        replayMarkerNextSequence: UInt64 = 0
    ) {
        self.generationID = generationID
        self.acknowledgedPrefixNextSequence = acknowledgedPrefixNextSequence
        self.acknowledgedPrefixEndOffset = acknowledgedPrefixEndOffset
        self.materializedPrefixNextSequence = materializedPrefixNextSequence ?? acknowledgedPrefixNextSequence
        self.materializedPrefixEndOffset = materializedPrefixEndOffset ?? acknowledgedPrefixEndOffset
        self.nextPartitionOrdinal = nextPartitionOrdinal
        self.nextSampleOffset = nextSampleOffset
        self.replayMarkerNextSequence = replayMarkerNextSequence
    }

    func encoded() -> Data {
        var data = Data(capacity: OmiLaunchCaptureCursorFormat.byteCount)
        data.append(OmiLaunchCaptureCursorFormat.magic)
        data.appendLittleEndian(OmiLaunchCaptureCursorFormat.version)
        data.append(uuidBytes: self.generationID)
        data.appendLittleEndian(self.acknowledgedPrefixNextSequence)
        data.appendLittleEndian(UInt64(self.acknowledgedPrefixEndOffset))
        data.appendLittleEndian(self.materializedPrefixNextSequence)
        data.appendLittleEndian(UInt64(self.materializedPrefixEndOffset))
        data.appendLittleEndian(self.nextPartitionOrdinal)
        data.appendLittleEndian(self.nextSampleOffset)
        data.appendLittleEndian(self.replayMarkerNextSequence)
        data.append(OmiLaunchCaptureDigest.truncated(data))
        return data
    }

    static func decode(_ data: Data) -> Result<Self, OmiLaunchCaptureCursorDefectReason> {
        guard data.count == OmiLaunchCaptureCursorFormat.byteCount else {
            return .failure(.invalidLength)
        }
        guard data.prefix(OmiLaunchCaptureCursorFormat.magic.count) == OmiLaunchCaptureCursorFormat.magic else {
            return .failure(.invalidMagic)
        }
        let versionOffset = OmiLaunchCaptureCursorFormat.magic.count
        guard data.uint16LE(at: versionOffset) == OmiLaunchCaptureCursorFormat.version else {
            return .failure(.unsupportedVersion)
        }
        let digestOffset = data.count - OmiLaunchCaptureCursorFormat.digestByteCount
        guard OmiLaunchCaptureDigest.truncated(data.prefix(digestOffset)) == data.suffix(OmiLaunchCaptureCursorFormat.digestByteCount) else {
            return .failure(.cursorChecksumMismatch)
        }
        let generationOffset = versionOffset + OmiLaunchCaptureCursorFormat.versionByteCount
        // `uuid(at:)` returns nil only for insufficient length, already guarded above.
        guard let generationID = data.uuid(at: generationOffset) else {
            return .failure(.invalidLength)
        }
        let sequenceOffset = generationOffset + OmiLaunchCaptureFormat.generationIDByteCount
        let endOffset = sequenceOffset + OmiLaunchCaptureCursorFormat.sequenceByteCount
        let acknowledgedEnd = data.uint64LE(at: endOffset)
        let materializedSequenceOffset = endOffset + OmiLaunchCaptureCursorFormat.offsetByteCount
        let materializedEndOffset = materializedSequenceOffset + OmiLaunchCaptureCursorFormat.sequenceByteCount
        let materializedEnd = data.uint64LE(at: materializedEndOffset)
        let ordinalOffset = materializedEndOffset + OmiLaunchCaptureCursorFormat.offsetByteCount
        let sampleOffset = ordinalOffset + OmiLaunchCaptureCursorFormat.sequenceByteCount
        let markerOffset = sampleOffset + OmiLaunchCaptureCursorFormat.sequenceByteCount
        guard acknowledgedEnd <= UInt64(Int.max), materializedEnd <= UInt64(Int.max),
              data.uint64LE(at: ordinalOffset) <= UInt64(Int.max),
              data.uint64LE(at: sequenceOffset) <= data.uint64LE(at: materializedSequenceOffset),
              acknowledgedEnd <= materializedEnd
        else {
            return .failure(.offsetOutOfRange)
        }
        return .success(Self(
            generationID: generationID,
            acknowledgedPrefixNextSequence: data.uint64LE(at: sequenceOffset),
            acknowledgedPrefixEndOffset: Int(acknowledgedEnd),
            materializedPrefixNextSequence: data.uint64LE(at: materializedSequenceOffset),
            materializedPrefixEndOffset: Int(materializedEnd),
            nextPartitionOrdinal: data.uint64LE(at: ordinalOffset),
            nextSampleOffset: data.uint64LE(at: sampleOffset),
            replayMarkerNextSequence: data.uint64LE(at: markerOffset)
        ))
    }
}

nonisolated enum OmiLaunchCaptureAcknowledgmentNoOpReason: String, Equatable, Sendable {
    case repeatedSequence
    case lowerSequence
}

nonisolated enum OmiLaunchCaptureAcknowledgmentRefusalReason: String, Equatable, Sendable {
    case foreignGeneration
    case noncontiguousFutureSequence
    case pastVerifiedPrefix
    case cursorUnreadable
    case cursorWriteFailed
    case cursorReplaceFailed
}

nonisolated enum OmiLaunchCaptureAcknowledgmentOutcome: Equatable, Sendable {
    case advanced
    case noOp(OmiLaunchCaptureAcknowledgmentNoOpReason)
    case refused(OmiLaunchCaptureAcknowledgmentRefusalReason)
}

nonisolated enum OmiLaunchCaptureRetirementOutcome: Equatable, Sendable {
    case deleted
    case quarantined
    case refusedActiveGeneration
    case refusedUnacknowledgedPrefix
    case refusedInvalidCursor
    case failed
}
