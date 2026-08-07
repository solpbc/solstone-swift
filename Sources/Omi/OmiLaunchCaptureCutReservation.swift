// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The intent is deliberately frontier-free.  Publishing it claims the reserved
/// generation, but does not yet assert that the sealed capture has stopped.
nonisolated enum OmiLaunchCaptureCutReservationFormat {
    static let fileName = "cut-reservation.cut"
    static let magic = Data("solcutint1".utf8)
    static let version: UInt16 = 2
    static let versionByteCount = UInt16.bitWidth / 8
    static let digestByteCount = OmiLaunchCaptureFormat.truncatedDigestByteCount
    static let byteCount = magic.count + versionByteCount
        + OmiLaunchCaptureFormat.generationIDByteCount
        + OmiLaunchCaptureFormat.generationIDByteCount
        + digestByteCount

    static func fileURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static func reservedRootURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(OmiLaunchCaptureFormat.reservedCaptureDirectoryName, isDirectory: true)
    }
}

nonisolated enum OmiLaunchCaptureCutFinalFormat {
    static let fileName = "cut-final.cut"
    static let magic = Data("solcutfin1".utf8)
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
}

nonisolated enum OmiLaunchCaptureCutReservationDefectReason: String, Error, Equatable, Sendable {
    case invalidLength
    case invalidMagic
    case unsupportedVersion
    case reservationChecksumMismatch
    case frontierOutOfRange
    case sealedGenerationMismatch
    case reservedGenerationMismatch
    case finalMismatch
    case readFailed
}

nonisolated struct OmiLaunchCaptureCutReservationDefect: Error, Equatable, Sendable {
    let reason: OmiLaunchCaptureCutReservationDefectReason
    let contentDigest: Data
}

nonisolated struct OmiLaunchCaptureCutReservation: Equatable, Sendable {
    let sealedGenerationID: UUID
    let reservedGenerationID: UUID

    func encoded() -> Data {
        var data = Data(capacity: OmiLaunchCaptureCutReservationFormat.byteCount)
        data.append(OmiLaunchCaptureCutReservationFormat.magic)
        data.appendLittleEndian(OmiLaunchCaptureCutReservationFormat.version)
        data.append(uuidBytes: self.sealedGenerationID)
        data.append(uuidBytes: self.reservedGenerationID)
        data.append(OmiLaunchCaptureDigest.truncated(data))
        return data
    }

    static func decode(_ data: Data) -> Result<Self, OmiLaunchCaptureCutReservationDefectReason> {
        Self.decode(data, magic: OmiLaunchCaptureCutReservationFormat.magic, version: OmiLaunchCaptureCutReservationFormat.version, byteCount: OmiLaunchCaptureCutReservationFormat.byteCount)
    }

    fileprivate static func decode(_ data: Data, magic: Data, version: UInt16, byteCount: Int) -> Result<Self, OmiLaunchCaptureCutReservationDefectReason> {
        guard data.count >= magic.count + OmiLaunchCaptureCutReservationFormat.versionByteCount else { return .failure(.invalidLength) }
        guard data.prefix(magic.count) == magic else { return .failure(.invalidMagic) }
        guard data.uint16LE(at: magic.count) == version else { return .failure(.unsupportedVersion) }
        guard data.count == byteCount else { return .failure(.invalidLength) }
        let digestOffset = data.count - OmiLaunchCaptureCutReservationFormat.digestByteCount
        guard OmiLaunchCaptureDigest.truncated(data.prefix(digestOffset)) == data.suffix(OmiLaunchCaptureCutReservationFormat.digestByteCount) else {
            return .failure(.reservationChecksumMismatch)
        }
        let sealedOffset = magic.count + OmiLaunchCaptureCutReservationFormat.versionByteCount
        let reservedOffset = sealedOffset + OmiLaunchCaptureFormat.generationIDByteCount
        guard let sealed = data.uuid(at: sealedOffset), let reserved = data.uuid(at: reservedOffset) else { return .failure(.invalidLength) }
        return .success(Self(sealedGenerationID: sealed, reservedGenerationID: reserved))
    }
}

nonisolated struct OmiLaunchCaptureCutFinal: Equatable, Sendable {
    let sealedGenerationID: UUID
    let sealedNextSequence: UInt64
    let sealedEndOffset: Int
    let reservedGenerationID: UUID

    func encoded() -> Data {
        var data = Data(capacity: OmiLaunchCaptureCutFinalFormat.byteCount)
        data.append(OmiLaunchCaptureCutFinalFormat.magic)
        data.appendLittleEndian(OmiLaunchCaptureCutFinalFormat.version)
        data.append(uuidBytes: self.sealedGenerationID)
        data.appendLittleEndian(self.sealedNextSequence)
        data.appendLittleEndian(UInt64(self.sealedEndOffset))
        data.append(uuidBytes: self.reservedGenerationID)
        data.append(OmiLaunchCaptureDigest.truncated(data))
        return data
    }

    static func decode(_ data: Data) -> Result<Self, OmiLaunchCaptureCutReservationDefectReason> {
        guard data.count >= OmiLaunchCaptureCutFinalFormat.magic.count + OmiLaunchCaptureCutFinalFormat.versionByteCount else { return .failure(.invalidLength) }
        guard data.prefix(OmiLaunchCaptureCutFinalFormat.magic.count) == OmiLaunchCaptureCutFinalFormat.magic else { return .failure(.invalidMagic) }
        let versionOffset = OmiLaunchCaptureCutFinalFormat.magic.count
        guard data.uint16LE(at: versionOffset) == OmiLaunchCaptureCutFinalFormat.version else { return .failure(.unsupportedVersion) }
        guard data.count == OmiLaunchCaptureCutFinalFormat.byteCount else { return .failure(.invalidLength) }
        let digestOffset = data.count - OmiLaunchCaptureCutFinalFormat.digestByteCount
        guard OmiLaunchCaptureDigest.truncated(data.prefix(digestOffset)) == data.suffix(OmiLaunchCaptureCutFinalFormat.digestByteCount) else { return .failure(.reservationChecksumMismatch) }
        let sealedOffset = versionOffset + OmiLaunchCaptureCutFinalFormat.versionByteCount
        let sequenceOffset = sealedOffset + OmiLaunchCaptureFormat.generationIDByteCount
        let offsetOffset = sequenceOffset + OmiLaunchCaptureCutFinalFormat.frontierByteCount
        let reservedOffset = offsetOffset + OmiLaunchCaptureCutFinalFormat.frontierByteCount
        guard let sealed = data.uuid(at: sealedOffset), let reserved = data.uuid(at: reservedOffset), data.uint64LE(at: offsetOffset) <= UInt64(Int.max) else { return .failure(.frontierOutOfRange) }
        return .success(Self(sealedGenerationID: sealed, sealedNextSequence: data.uint64LE(at: sequenceOffset), sealedEndOffset: Int(data.uint64LE(at: offsetOffset)), reservedGenerationID: reserved))
    }
}

nonisolated enum OmiLaunchCaptureCutReservationReadOutcome: Equatable, Sendable {
    case absent
    case valid(OmiLaunchCaptureCutReservation)
    case unreadable(OmiLaunchCaptureCutReservationDefect)
}

nonisolated enum OmiLaunchCaptureCutFinalReadOutcome: Equatable, Sendable {
    case absent
    case valid(OmiLaunchCaptureCutFinal)
    case unreadable(OmiLaunchCaptureCutReservationDefect)
}

nonisolated enum OmiLaunchCaptureCutReservationCommitRefusal: Equatable, Sendable { case writeFailed, replaceFailed }
nonisolated enum OmiLaunchCaptureCutReservationCommitOutcome: Equatable, Sendable { case committed, refused(OmiLaunchCaptureCutReservationCommitRefusal) }

nonisolated struct OmiLaunchCaptureCutReservationStore: Sendable {
    let rootURL: URL
    let io: any OmiLaunchCaptureIO
    init(rootURL: URL, io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()) { self.rootURL = rootURL; self.io = io }
    var fileURL: URL { OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.rootURL) }
    func read() -> OmiLaunchCaptureCutReservationReadOutcome {
        switch self.readData(at: self.fileURL, byteCount: OmiLaunchCaptureCutReservationFormat.byteCount) {
        case .success(nil): return .absent
        case .failure(let defect): return .unreadable(defect)
        case .success(.some(let data)):
            switch OmiLaunchCaptureCutReservation.decode(data) { case .success(let value): return .valid(value); case .failure(let reason): return .unreadable(self.defect(reason: reason, bytes: data)) }
        }
    }
    func commit(_ reservation: OmiLaunchCaptureCutReservation) -> OmiLaunchCaptureCutReservationCommitOutcome { self.commit(reservation.encoded(), fileURL: self.fileURL, tempPrefix: ".cut-reservation") }

    fileprivate func readData(at url: URL, byteCount: Int) -> Result<Data?, OmiLaunchCaptureCutReservationDefect> {
        do {
            guard try self.io.fileExists(at: url) else { return .success(nil) }
            let token = try self.io.openForReading(at: url); defer { try? self.io.close(token) }
            return .success(try self.io.read(token, offset: 0, count: byteCount + 1))
        } catch { return .failure(self.defect(reason: .readFailed, bytes: Data())) }
    }
    fileprivate func commit(_ data: Data, fileURL: URL, tempPrefix: String) -> OmiLaunchCaptureCutReservationCommitOutcome {
        let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(tempPrefix)-\(UUID().uuidString.lowercased()).tmp", isDirectory: false)
        let token: OmiLaunchCaptureFileToken
        do { token = try self.io.openNewFileForWriting(at: tempURL) } catch { return .refused(.writeFailed) }
        do { try self.io.append(data, to: token); try self.io.fullSynchronize(token); try self.io.close(token) }
        catch { try? self.io.close(token); try? self.io.removeItem(at: tempURL); return .refused(.writeFailed) }
        do { try self.io.atomicReplaceItem(at: tempURL, with: fileURL); return .committed }
        catch { try? self.io.removeItem(at: tempURL); return .refused(.replaceFailed) }
    }
    fileprivate func defect(reason: OmiLaunchCaptureCutReservationDefectReason, bytes: Data) -> OmiLaunchCaptureCutReservationDefect { .init(reason: reason, contentDigest: OmiLaunchCaptureDigest.truncated(bytes)) }
}

nonisolated struct OmiLaunchCaptureCutFinalStore: Sendable {
    let rootURL: URL
    let io: any OmiLaunchCaptureIO
    init(rootURL: URL, io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()) { self.rootURL = rootURL; self.io = io }
    var fileURL: URL { OmiLaunchCaptureCutFinalFormat.fileURL(rootURL: self.rootURL) }
    func read() -> OmiLaunchCaptureCutFinalReadOutcome {
        let reservationStore = OmiLaunchCaptureCutReservationStore(rootURL: self.rootURL, io: self.io)
        switch reservationStore.readData(at: self.fileURL, byteCount: OmiLaunchCaptureCutFinalFormat.byteCount) {
        case .success(nil): return .absent
        case .failure(let defect): return .unreadable(defect)
        case .success(.some(let data)):
            switch OmiLaunchCaptureCutFinal.decode(data) { case .success(let value): return .valid(value); case .failure(let reason): return .unreadable(reservationStore.defect(reason: reason, bytes: data)) }
        }
    }
    func commit(_ final: OmiLaunchCaptureCutFinal) -> OmiLaunchCaptureCutReservationCommitOutcome {
        OmiLaunchCaptureCutReservationStore(rootURL: self.rootURL, io: self.io).commit(final.encoded(), fileURL: self.fileURL, tempPrefix: ".cut-final")
    }
}
