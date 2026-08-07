// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OmiLaunchCaptureCutReservationFormat {
    // Fixed 76-byte layout (all integers little-endian):
    //   0: 10-byte magic "solcutres1"
    //  10:  2-byte version
    //  12: 16-byte sealed generation UUID
    //  28:  8-byte sealed next sequence
    //  36:  8-byte sealed end offset
    //  44: 16-byte reserved generation UUID
    //  60: 16-byte truncated digest over bytes 0 through 59
    static let fileName = "cut-reservation.cut"
    static let magic = Data("solcutres1".utf8)
    static let version: UInt16 = 1
    static let versionByteCount = UInt16.bitWidth / 8
    static let frontierByteCount = UInt64.bitWidth / 8
    static let digestByteCount = OmiLaunchCaptureFormat.truncatedDigestByteCount
    static let byteCount = magic.count + versionByteCount
        + OmiLaunchCaptureFormat.generationIDByteCount
        + frontierByteCount + frontierByteCount
        + OmiLaunchCaptureFormat.generationIDByteCount
        + digestByteCount

    static func fileURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static func reservedRootURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(OmiLaunchCaptureFormat.reservedCaptureDirectoryName, isDirectory: true)
    }
}

nonisolated enum OmiLaunchCaptureCutReservationDefectReason: String, Error, Equatable, Sendable {
    case invalidLength
    case invalidMagic
    case unsupportedVersion
    case reservationChecksumMismatch
    case frontierOutOfRange
    case sealedGenerationMismatch
    case reservedGenerationMismatch
    case readFailed
}

nonisolated struct OmiLaunchCaptureCutReservationDefect: Equatable, Sendable {
    let reason: OmiLaunchCaptureCutReservationDefectReason
    let contentDigest: Data
}

nonisolated struct OmiLaunchCaptureCutReservation: Equatable, Sendable {
    let sealedGenerationID: UUID
    let sealedNextSequence: UInt64
    let sealedEndOffset: Int
    let reservedGenerationID: UUID

    func encoded() -> Data {
        var data = Data(capacity: OmiLaunchCaptureCutReservationFormat.byteCount)
        data.append(OmiLaunchCaptureCutReservationFormat.magic)
        data.appendLittleEndian(OmiLaunchCaptureCutReservationFormat.version)
        data.append(uuidBytes: self.sealedGenerationID)
        data.appendLittleEndian(self.sealedNextSequence)
        data.appendLittleEndian(UInt64(self.sealedEndOffset))
        data.append(uuidBytes: self.reservedGenerationID)
        data.append(OmiLaunchCaptureDigest.truncated(data))
        return data
    }

    static func decode(_ data: Data) -> Result<Self, OmiLaunchCaptureCutReservationDefectReason> {
        guard data.count >= OmiLaunchCaptureCutReservationFormat.magic.count + OmiLaunchCaptureCutReservationFormat.versionByteCount else {
            return .failure(.invalidLength)
        }
        guard data.prefix(OmiLaunchCaptureCutReservationFormat.magic.count) == OmiLaunchCaptureCutReservationFormat.magic else {
            return .failure(.invalidMagic)
        }
        let versionOffset = OmiLaunchCaptureCutReservationFormat.magic.count
        guard data.uint16LE(at: versionOffset) == OmiLaunchCaptureCutReservationFormat.version else {
            return .failure(.unsupportedVersion)
        }
        guard data.count == OmiLaunchCaptureCutReservationFormat.byteCount else {
            return .failure(.invalidLength)
        }
        let digestOffset = data.count - OmiLaunchCaptureCutReservationFormat.digestByteCount
        guard OmiLaunchCaptureDigest.truncated(data.prefix(digestOffset)) == data.suffix(OmiLaunchCaptureCutReservationFormat.digestByteCount) else {
            return .failure(.reservationChecksumMismatch)
        }
        let sealedOffset = versionOffset + OmiLaunchCaptureCutReservationFormat.versionByteCount
        guard let sealedGenerationID = data.uuid(at: sealedOffset) else { return .failure(.invalidLength) }
        let sequenceOffset = sealedOffset + OmiLaunchCaptureFormat.generationIDByteCount
        let endOffset = sequenceOffset + OmiLaunchCaptureCutReservationFormat.frontierByteCount
        let reservedOffset = endOffset + OmiLaunchCaptureCutReservationFormat.frontierByteCount
        guard let reservedGenerationID = data.uuid(at: reservedOffset),
              data.uint64LE(at: endOffset) <= UInt64(Int.max)
        else { return .failure(.frontierOutOfRange) }
        return .success(Self(
            sealedGenerationID: sealedGenerationID,
            sealedNextSequence: data.uint64LE(at: sequenceOffset),
            sealedEndOffset: Int(data.uint64LE(at: endOffset)),
            reservedGenerationID: reservedGenerationID
        ))
    }
}

nonisolated enum OmiLaunchCaptureCutReservationReadOutcome: Equatable, Sendable {
    case absent
    case valid(OmiLaunchCaptureCutReservation)
    case unreadable(OmiLaunchCaptureCutReservationDefect)
}

nonisolated enum OmiLaunchCaptureCutReservationCommitRefusal: Equatable, Sendable {
    case writeFailed
    case replaceFailed
}

nonisolated enum OmiLaunchCaptureCutReservationCommitOutcome: Equatable, Sendable {
    case committed
    case refused(OmiLaunchCaptureCutReservationCommitRefusal)
}

nonisolated struct OmiLaunchCaptureCutReservationStore: Sendable {
    let rootURL: URL
    let io: any OmiLaunchCaptureIO

    init(rootURL: URL, io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()) {
        self.rootURL = rootURL
        self.io = io
    }

    var fileURL: URL { OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.rootURL) }

    func read() -> OmiLaunchCaptureCutReservationReadOutcome {
        do {
            guard try self.io.fileExists(at: self.fileURL) else { return .absent }
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            let data = try self.io.read(token, offset: 0, count: OmiLaunchCaptureCutReservationFormat.byteCount + 1)
            switch OmiLaunchCaptureCutReservation.decode(data) {
            case .success(let reservation): return .valid(reservation)
            case .failure(let reason): return .unreadable(self.defect(reason: reason, bytes: data))
            }
        } catch {
            return .unreadable(self.defect(reason: .readFailed, bytes: Data()))
        }
    }

    func commit(_ reservation: OmiLaunchCaptureCutReservation) -> OmiLaunchCaptureCutReservationCommitOutcome {
        let tempURL = self.fileURL.deletingLastPathComponent()
            .appendingPathComponent(".cut-reservation-\(UUID().uuidString.lowercased()).tmp", isDirectory: false)
        let token: OmiLaunchCaptureFileToken
        do {
            token = try self.io.openNewFileForWriting(at: tempURL)
        } catch {
            return .refused(.writeFailed)
        }
        var shouldClose = true
        do {
            try self.io.append(reservation.encoded(), to: token)
            // Synchronize the complete temp before close; a crash before replacement
            // leaves no claim, while replacement publishes only this synced payload.
            try self.io.fullSynchronize(token)
            try self.io.close(token)
            shouldClose = false
        } catch {
            if shouldClose { try? self.io.close(token) }
            try? self.io.removeItem(at: tempURL)
            return .refused(.writeFailed)
        }
        do {
            // Same-directory replacement is the claim boundary: before it the canonical
            // file is absent; after it, readers observe the complete synchronized record.
            try self.io.atomicReplaceItem(at: tempURL, with: self.fileURL)
            return .committed
        } catch {
            try? self.io.removeItem(at: tempURL)
            return .refused(.replaceFailed)
        }
    }

    private func defect(reason: OmiLaunchCaptureCutReservationDefectReason, bytes: Data) -> OmiLaunchCaptureCutReservationDefect {
        OmiLaunchCaptureCutReservationDefect(reason: reason, contentDigest: OmiLaunchCaptureDigest.truncated(bytes))
    }
}
