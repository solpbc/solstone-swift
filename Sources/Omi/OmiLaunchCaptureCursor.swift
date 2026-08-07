// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OmiLaunchCaptureCursorFormat {
    static let fileExtension = "cursor"
    static let magic = Data("solcursor1".utf8)
    static let version: UInt16 = 1
    static let versionByteCount = UInt16.bitWidth / 8
    static let sequenceByteCount = UInt64.bitWidth / 8
    static let offsetByteCount = UInt64.bitWidth / 8
    static let digestByteCount = OmiLaunchCaptureFormat.truncatedDigestByteCount
    static let byteCount = magic.count + versionByteCount
        + OmiLaunchCaptureFormat.generationIDByteCount
        + sequenceByteCount + offsetByteCount + digestByteCount

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

    func encoded() -> Data {
        var data = Data(capacity: OmiLaunchCaptureCursorFormat.byteCount)
        data.append(OmiLaunchCaptureCursorFormat.magic)
        data.appendLittleEndian(OmiLaunchCaptureCursorFormat.version)
        data.append(uuidBytes: self.generationID)
        data.appendLittleEndian(self.acknowledgedPrefixNextSequence)
        data.appendLittleEndian(UInt64(self.acknowledgedPrefixEndOffset))
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
        guard acknowledgedEnd <= UInt64(Int.max) else {
            return .failure(.offsetOutOfRange)
        }
        return .success(Self(
            generationID: generationID,
            acknowledgedPrefixNextSequence: data.uint64LE(at: sequenceOffset),
            acknowledgedPrefixEndOffset: Int(acknowledgedEnd)
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
