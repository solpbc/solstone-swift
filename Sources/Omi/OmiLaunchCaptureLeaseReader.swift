// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class OmiLaunchCaptureLeaseReader {
    private enum CursorRead {
        case valid(OmiLaunchCaptureCursor)
        case initial
        case unreadable
    }

    private let rootURL: URL
    private let generationID: UUID
    private let io: any OmiLaunchCaptureIO

    private(set) var peakLeaseResidentPayloadBytes = 0

    init(rootURL: URL, generationID: UUID, io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()) {
        self.rootURL = rootURL
        self.generationID = generationID
        self.io = io
    }

    var fileURL: URL {
        OmiLaunchCaptureFormat.fileURL(rootURL: self.rootURL, generationID: self.generationID)
    }

    var cursorURL: URL {
        OmiLaunchCaptureCursorFormat.fileURL(rootURL: self.rootURL, generationID: self.generationID)
    }

    func acknowledgedPosition() -> OmiLaunchCaptureReadPosition? {
        guard let cursor = self.resolvedCursor(from: self.readCursor()) else { return nil }
        return OmiLaunchCaptureReadPosition(
            generationID: cursor.generationID,
            nextSequence: cursor.acknowledgedPrefixNextSequence,
            offset: cursor.acknowledgedPrefixEndOffset
        )
    }

    func hasDurableAcknowledgment() -> Bool {
        if case .valid = self.readCursor() {
            return true
        }
        return false
    }

    func lease() -> OmiLaunchCaptureLeaseOutcome {
        guard let scan = self.scanCurrent() else { return .unavailable(.captureUnreadable) }
        let cursorRead = self.readCursor()
        switch cursorRead {
        case .valid, .initial:
            guard let cursor = self.resolvedCursor(from: cursorRead) else {
                return .unavailable(.cursorUnreadable)
            }
            return self.makeLease(cursor: cursor, scan: scan)
        case .unreadable:
            return .unavailable(.cursorUnreadable)
        }
    }

    func lease(from position: OmiLaunchCaptureReadPosition) -> OmiLaunchCaptureLeaseOutcome {
        guard position.generationID == self.generationID else { return .unavailable(.cursorDoesNotMatchCapture) }
        guard let scan = self.scanCurrent() else { return .unavailable(.captureUnreadable) }
        return self.makeLease(cursor: OmiLaunchCaptureCursor(
            generationID: position.generationID,
            acknowledgedPrefixNextSequence: position.nextSequence,
            acknowledgedPrefixEndOffset: position.offset
        ), scan: scan)
    }

    func acknowledge(throughSequence: UInt64, generationID: UUID? = nil) -> OmiLaunchCaptureAcknowledgmentOutcome {
        if let generationID, generationID != self.generationID {
            return .refused(.foreignGeneration)
        }
        let cursorRead = self.readCursor()
        switch cursorRead {
        case .valid, .initial:
            guard let cursor = self.resolvedCursor(from: cursorRead) else {
                return .refused(.cursorUnreadable)
            }
            return self.acknowledge(throughSequence: throughSequence, cursor: cursor)
        case .unreadable:
            return .refused(.cursorUnreadable)
        }
    }

    func retireIfEligible(activeGenerationID: UUID?) -> OmiLaunchCaptureRetirementOutcome {
        guard case .valid(let cursor) = self.readCursor(), cursor.generationID == self.generationID else {
            return .refusedInvalidCursor
        }
        guard activeGenerationID != self.generationID else { return .refusedActiveGeneration }
        guard let scan = self.scanCurrent() else { return .failed }
        guard cursor.acknowledgedPrefixEndOffset == scan.verifiedPrefixEndOffset else {
            return .refusedUnacknowledgedPrefix
        }
        do {
            if scan.boundaryReason == nil {
                let fileSize = try self.io.fileSize(at: self.fileURL)
                guard cursor.acknowledgedPrefixEndOffset == fileSize else {
                    return .refusedUnacknowledgedPrefix
                }
                try self.io.removeItem(at: self.fileURL)
                try? self.io.removeItem(at: self.cursorURL)
                return .deleted
            }
            let quarantineURL = self.rootURL
                .appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName, isDirectory: true)
                .appendingPathComponent(
                    "\(self.fileURL.deletingPathExtension().lastPathComponent)-boundary-\(scan.boundaryOffset ?? scan.verifiedPrefixEndOffset).\(OmiLaunchCaptureFormat.fileExtension)",
                    isDirectory: false
                )
            try self.io.moveItem(at: self.fileURL, to: quarantineURL)
            try? self.io.removeItem(at: self.cursorURL)
            return .quarantined
        } catch {
            return .failed
        }
    }

    private func makeLease(cursor: OmiLaunchCaptureCursor, scan: OmiLaunchCaptureScanResult) -> OmiLaunchCaptureLeaseOutcome {
        guard cursor.generationID == self.generationID,
              cursor.acknowledgedPrefixNextSequence <= scan.verifiedPrefixNextSequence,
              cursor.acknowledgedPrefixEndOffset <= scan.verifiedPrefixEndOffset
        else { return .unavailable(.cursorDoesNotMatchCapture) }
        guard cursor.acknowledgedPrefixNextSequence < scan.verifiedPrefixNextSequence else {
            return cursor.acknowledgedPrefixEndOffset == scan.verifiedPrefixEndOffset ? .empty : .unavailable(.cursorDoesNotMatchCapture)
        }
        do {
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            let firstHeader = try self.io.read(token, offset: cursor.acknowledgedPrefixEndOffset, count: OmiLaunchCaptureFormat.headerByteCount)
            guard case .success(let first) = OmiLaunchCaptureHeader.decode(firstHeader),
                  first.generationID == self.generationID,
                  first.sequence == cursor.acknowledgedPrefixNextSequence
            else { return .unavailable(.cursorDoesNotMatchCapture) }

            let limit = OmiLaunchCaptureFormat.maximumResidentPayloadBytes / OmiLaunchCaptureFormat.maximumPayloadBytes
            guard let firstRecord = try self.readRecord(
                token: token,
                offset: cursor.acknowledgedPrefixEndOffset,
                expectedSequence: cursor.acknowledgedPrefixNextSequence
            ) else { return .unavailable(.captureUnreadable) }
            var records = [firstRecord]
            var sequence = cursor.acknowledgedPrefixNextSequence + 1
            var offset = cursor.acknowledgedPrefixEndOffset
                + OmiLaunchCaptureFormat.headerByteCount
                + firstRecord.payload.count
                + OmiLaunchCaptureFormat.recordTagByteCount
            while records.count < limit, sequence < scan.verifiedPrefixNextSequence {
                guard let record = try self.readRecord(token: token, offset: offset, expectedSequence: sequence) else {
                    return .unavailable(.captureUnreadable)
                }
                records.append(record)
                offset += OmiLaunchCaptureFormat.headerByteCount + record.payload.count + OmiLaunchCaptureFormat.recordTagByteCount
                sequence += 1
            }
            let resident = records.reduce(0) { $0 + $1.payload.count }
            self.peakLeaseResidentPayloadBytes = max(self.peakLeaseResidentPayloadBytes, resident)
            let last = records[records.index(before: records.endIndex)]
            return .lease(OmiLaunchCaptureLease(
                generationID: self.generationID,
                startSequence: cursor.acknowledgedPrefixNextSequence,
                startOffset: cursor.acknowledgedPrefixEndOffset,
                throughSequence: last.sequence,
                endOffset: offset,
                records: records
            ))
        } catch {
            return .unavailable(.captureUnreadable)
        }
    }

    private func acknowledge(
        throughSequence: UInt64,
        cursor: OmiLaunchCaptureCursor
    ) -> OmiLaunchCaptureAcknowledgmentOutcome {
        if cursor.acknowledgedPrefixNextSequence > 0,
           throughSequence == cursor.acknowledgedPrefixNextSequence - 1 {
            return .noOp(.repeatedSequence)
        }
        if throughSequence < cursor.acknowledgedPrefixNextSequence {
            return .noOp(.lowerSequence)
        }
        guard let scan = self.scanCurrent() else { return .refused(.cursorUnreadable) }
        guard cursor.acknowledgedPrefixNextSequence <= scan.verifiedPrefixNextSequence,
              cursor.acknowledgedPrefixEndOffset <= scan.verifiedPrefixEndOffset
        else { return .refused(.noncontiguousFutureSequence) }
        guard throughSequence < scan.verifiedPrefixNextSequence else { return .refused(.pastVerifiedPrefix) }
        do {
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            guard let endOffset = try OmiLaunchCaptureLeaseLogic.headerEnd(
                generationID: self.generationID,
                startSequence: cursor.acknowledgedPrefixNextSequence,
                startOffset: cursor.acknowledgedPrefixEndOffset,
                throughSequence: throughSequence,
                read: { try self.io.read(token, offset: $0, count: $1) }
            ) else { return .refused(.noncontiguousFutureSequence) }
            let next = OmiLaunchCaptureCursor(
                generationID: self.generationID,
                acknowledgedPrefixNextSequence: throughSequence + 1,
                acknowledgedPrefixEndOffset: endOffset
            )
            return self.writeCursor(next)
        } catch {
            return .refused(.cursorUnreadable)
        }
    }

    private func scanCurrent() -> OmiLaunchCaptureScanResult? {
        do {
            guard try self.io.fileExists(at: self.fileURL) else { return OmiLaunchCaptureScanResult() }
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            return OmiLaunchCaptureLogic.scan(
                generationID: self.generationID,
                fileSize: try self.io.fileSize(at: self.fileURL),
                read: { try self.io.read(token, offset: $0, count: $1) }
            )
        } catch {
            return nil
        }
    }

    private func readCursor() -> CursorRead {
        do {
            guard try self.io.fileExists(at: self.cursorURL) else { return .initial }
            let token = try self.io.openForReading(at: self.cursorURL)
            defer { try? self.io.close(token) }
            guard try self.io.fileSize(at: self.cursorURL) == OmiLaunchCaptureCursorFormat.byteCount else { return .initial }
            let data = try self.io.read(token, offset: 0, count: OmiLaunchCaptureCursorFormat.byteCount)
            guard let cursor = OmiLaunchCaptureCursor.decode(data), cursor.generationID == self.generationID else { return .initial }
            return .valid(cursor)
        } catch {
            return .unreadable
        }
    }

    private func resolvedCursor(from cursorRead: CursorRead) -> OmiLaunchCaptureCursor? {
        switch cursorRead {
        case .valid(let cursor):
            return cursor
        case .initial:
            return OmiLaunchCaptureCursor(
                generationID: self.generationID,
                acknowledgedPrefixNextSequence: 0,
                acknowledgedPrefixEndOffset: 0
            )
        case .unreadable:
            return nil
        }
    }

    private func readRecord(
        token: OmiLaunchCaptureFileToken,
        offset: Int,
        expectedSequence: UInt64
    ) throws -> OmiLaunchCaptureRecord? {
        let headerData = try self.io.read(token, offset: offset, count: OmiLaunchCaptureFormat.headerByteCount)
        guard case .success(let header) = OmiLaunchCaptureHeader.decode(headerData),
              header.generationID == self.generationID,
              header.sequence == expectedSequence
        else { return nil }
        let bodyCount = header.declaredPayloadBytes + OmiLaunchCaptureFormat.recordTagByteCount
        let body = try self.io.read(token, offset: offset + OmiLaunchCaptureFormat.headerByteCount, count: bodyCount)
        guard body.count == bodyCount else { return nil }
        let payload = Data(body.prefix(header.declaredPayloadBytes))
        guard OmiLaunchCaptureDigest.recordTag(header: headerData, payload: payload) == body.suffix(OmiLaunchCaptureFormat.recordTagByteCount) else {
            return nil
        }
        return OmiLaunchCaptureRecord(
            generationID: header.generationID,
            sequence: header.sequence,
            acquiredAtUnixMicros: header.acquiredAtUnixMicros,
            payload: payload
        )
    }

    private func writeCursor(_ cursor: OmiLaunchCaptureCursor) -> OmiLaunchCaptureAcknowledgmentOutcome {
        let tempURL = self.cursorURL.deletingLastPathComponent()
            .appendingPathComponent(".cursor-\(UUID().uuidString.lowercased()).tmp", isDirectory: false)
        let token: OmiLaunchCaptureFileToken
        do {
            token = try self.io.openNewFileForWriting(at: tempURL)
        } catch {
            return .refused(.cursorWriteFailed)
        }
        var shouldClose = true
        do {
            try self.io.append(cursor.encoded(), to: token)
            try self.io.fullSynchronize(token)
            try self.io.close(token)
            shouldClose = false
        } catch {
            if shouldClose { try? self.io.close(token) }
            try? self.io.removeItem(at: tempURL)
            return .refused(.cursorWriteFailed)
        }
        do {
            // Like IntegrationGateFileStore, this commits a synced same-directory temp without a directory fsync.
            try self.io.atomicReplaceItem(at: tempURL, with: self.cursorURL)
            return .advanced
        } catch {
            try? self.io.removeItem(at: tempURL)
            return .refused(.cursorReplaceFailed)
        }
    }
}
