// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class OmiLaunchCaptureLeaseReader {
    private enum CursorRead {
        case valid(OmiLaunchCaptureCursor)
        case initial
        case unreadable(OmiLaunchCaptureCursorDefect)
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
        switch self.readCursor() {
        case .valid(let cursor):
            return OmiLaunchCaptureReadPosition(
                generationID: cursor.generationID,
                nextSequence: cursor.acknowledgedPrefixNextSequence,
                offset: cursor.acknowledgedPrefixEndOffset
            )
        case .initial:
            return OmiLaunchCaptureReadPosition(generationID: self.generationID, nextSequence: 0, offset: 0)
        case .unreadable:
            return nil
        }
    }

    func materializedPosition() -> OmiLaunchCaptureReadPosition? {
        switch self.readCursor() {
        case .valid(let cursor):
            // v2 commits both prefixes atomically. A divergent cursor can only be
            // evidence from an interrupted earlier build, so re-derive from the
            // acknowledged prefix rather than skipping an unsettled handoff.
            if cursor.materializedPrefixNextSequence > cursor.acknowledgedPrefixNextSequence {
                return OmiLaunchCaptureReadPosition(generationID: cursor.generationID, nextSequence: cursor.acknowledgedPrefixNextSequence, offset: cursor.acknowledgedPrefixEndOffset)
            }
            return OmiLaunchCaptureReadPosition(generationID: cursor.generationID, nextSequence: cursor.materializedPrefixNextSequence, offset: cursor.materializedPrefixEndOffset)
        case .initial:
            return OmiLaunchCaptureReadPosition(generationID: self.generationID, nextSequence: 0, offset: 0)
        case .unreadable:
            return nil
        }
    }

    func cursor() -> OmiLaunchCaptureCursor? {
        switch self.readCursor() {
        case .valid(let cursor): return cursor
        case .initial:
            return OmiLaunchCaptureCursor(generationID: self.generationID, acknowledgedPrefixNextSequence: 0, acknowledgedPrefixEndOffset: 0)
        case .unreadable:
            return nil
        }
    }

    func advanceMaterialized(
        throughSequence: UInt64,
        endOffset: Int,
        nextPartitionOrdinal: UInt64,
        nextSampleOffset: UInt64
    ) -> OmiLaunchCaptureAcknowledgmentOutcome {
        let cursorRead = self.readCursor()
        let cursor: OmiLaunchCaptureCursor
        switch cursorRead {
        case .valid(let value): cursor = value
        case .initial:
            cursor = OmiLaunchCaptureCursor(generationID: self.generationID, acknowledgedPrefixNextSequence: 0, acknowledgedPrefixEndOffset: 0)
        case .unreadable: return .refused(.cursorUnreadable)
        }
        guard cursor.materializedPrefixNextSequence <= throughSequence + 1,
              cursor.acknowledgedPrefixNextSequence <= throughSequence + 1
        else { return .refused(.noncontiguousFutureSequence) }
        let position = OmiLaunchCaptureReadPosition(
            generationID: self.generationID,
            nextSequence: cursor.materializedPrefixNextSequence,
            offset: cursor.materializedPrefixEndOffset
        )
        guard let scan = self.scanCurrent(from: position),
              throughSequence < scan.verifiedPrefixNextSequence
        else { return .refused(.pastVerifiedPrefix) }
        do {
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            guard try OmiLaunchCaptureLeaseLogic.headerEnd(
                generationID: self.generationID,
                startSequence: position.nextSequence,
                startOffset: position.offset,
                throughSequence: throughSequence,
                read: { try self.io.read(token, offset: $0, count: $1) }
            ) == endOffset else { return .refused(.pastVerifiedPrefix) }
        } catch {
            return .refused(.cursorUnreadable)
        }
        let next = OmiLaunchCaptureCursor(
            generationID: self.generationID,
            acknowledgedPrefixNextSequence: cursor.acknowledgedPrefixNextSequence,
            acknowledgedPrefixEndOffset: cursor.acknowledgedPrefixEndOffset,
            materializedPrefixNextSequence: throughSequence + 1,
            materializedPrefixEndOffset: endOffset,
            nextPartitionOrdinal: nextPartitionOrdinal,
            nextSampleOffset: nextSampleOffset,
            replayMarkerNextSequence: cursor.replayMarkerNextSequence
        )
        return self.writeCursor(next)
    }

    func commitSettled(
        throughSequence: UInt64,
        nextPartitionOrdinal: UInt64,
        nextSampleOffset: UInt64
    ) -> OmiLaunchCaptureAcknowledgmentOutcome {
        let cursorRead = self.readCursor()
        let cursor: OmiLaunchCaptureCursor
        switch cursorRead {
        case .valid(let value): cursor = value
        case .initial:
            cursor = OmiLaunchCaptureCursor(generationID: self.generationID, acknowledgedPrefixNextSequence: 0, acknowledgedPrefixEndOffset: 0)
        case .unreadable: return .refused(.cursorUnreadable)
        }
        if cursor.acknowledgedPrefixNextSequence > 0,
           throughSequence == cursor.acknowledgedPrefixNextSequence - 1 {
            return .noOp(.repeatedSequence)
        }
        guard throughSequence >= cursor.acknowledgedPrefixNextSequence else {
            return .noOp(.lowerSequence)
        }
        guard let scan = self.scanCurrent(), throughSequence < scan.verifiedPrefixNextSequence else {
            return .refused(.pastVerifiedPrefix)
        }
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
            // Owners are gated before this one atomic cursor replacement. A crash
            // therefore exposes either neither prefix advance or both together.
            return self.writeCursor(OmiLaunchCaptureCursor(
                generationID: self.generationID,
                acknowledgedPrefixNextSequence: throughSequence + 1,
                acknowledgedPrefixEndOffset: endOffset,
                materializedPrefixNextSequence: throughSequence + 1,
                materializedPrefixEndOffset: endOffset,
                nextPartitionOrdinal: nextPartitionOrdinal,
                nextSampleOffset: nextSampleOffset,
                replayMarkerNextSequence: cursor.replayMarkerNextSequence
            ))
        } catch {
            return .refused(.cursorUnreadable)
        }
    }

    func advanceReplayMarkers(through sequence: UInt64) -> OmiLaunchCaptureAcknowledgmentOutcome {
        let cursorRead = self.readCursor()
        let cursor: OmiLaunchCaptureCursor
        switch cursorRead {
        case .valid(let value): cursor = value
        case .initial:
            cursor = OmiLaunchCaptureCursor(generationID: self.generationID, acknowledgedPrefixNextSequence: 0, acknowledgedPrefixEndOffset: 0)
        case .unreadable: return .refused(.cursorUnreadable)
        }
        guard cursor.replayMarkerNextSequence <= sequence else { return .noOp(.lowerSequence) }
        guard sequence < UInt64.max else { return .refused(.pastVerifiedPrefix) }
        let next = OmiLaunchCaptureCursor(
            generationID: self.generationID,
            acknowledgedPrefixNextSequence: cursor.acknowledgedPrefixNextSequence,
            acknowledgedPrefixEndOffset: cursor.acknowledgedPrefixEndOffset,
            materializedPrefixNextSequence: cursor.materializedPrefixNextSequence,
            materializedPrefixEndOffset: cursor.materializedPrefixEndOffset,
            nextPartitionOrdinal: cursor.nextPartitionOrdinal,
            nextSampleOffset: cursor.nextSampleOffset,
            replayMarkerNextSequence: sequence + 1
        )
        return self.writeCursor(next)
    }

    func hasDurableAcknowledgment() -> Bool {
        if case .valid = self.readCursor() {
            return true
        }
        return false
    }

    func cursorDefect() -> OmiLaunchCaptureCursorDefect? {
        guard case .unreadable(let defect) = self.readCursor() else { return nil }
        return defect
    }

    // Ordering only needs the immutable first header; do not acquire a full lease
    // (and therefore do not rescan a generation) from a sort comparator.
    func captureStartTime() -> Int64? {
        do {
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            let data = try self.io.read(token, offset: 0, count: OmiLaunchCaptureFormat.headerByteCount)
            guard case .success(let header) = OmiLaunchCaptureHeader.decode(data),
                  header.generationID == self.generationID,
                  header.sequence == 0
            else { return nil }
            return header.acquiredAtUnixMicros
        } catch {
            return nil
        }
    }

    func lease() -> OmiLaunchCaptureLeaseOutcome {
        guard let scan = self.scanCurrent() else { return .unavailable(.captureUnreadable) }
        let cursorRead = self.readCursor()
        switch cursorRead {
        case .valid(let cursor):
            return self.makeLease(cursor: cursor, scan: scan)
        case .initial:
            return self.makeLease(cursor: OmiLaunchCaptureCursor(
                generationID: self.generationID,
                acknowledgedPrefixNextSequence: 0,
                acknowledgedPrefixEndOffset: 0
            ), scan: scan)
        case .unreadable:
            return .unavailable(.cursorUnreadable)
        }
    }

    func lease(from position: OmiLaunchCaptureReadPosition) -> OmiLaunchCaptureLeaseOutcome {
        guard position.generationID == self.generationID else { return .unavailable(.cursorDoesNotMatchCapture) }
        // Recovery has already verified the committed prefix. Batch materialization
        // only needs to validate the suffix beginning at its durable frontier.
        guard let scan = self.scanCurrent(from: position) else { return .unavailable(.captureUnreadable) }
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
        case .valid(let cursor):
            return self.acknowledge(throughSequence: throughSequence, cursor: cursor)
        case .initial:
            return self.acknowledge(throughSequence: throughSequence, cursor: OmiLaunchCaptureCursor(
                generationID: self.generationID,
                acknowledgedPrefixNextSequence: 0,
                acknowledgedPrefixEndOffset: 0
            ))
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

            let limit = OmiLaunchCaptureFormat.maximumRecordsPerLease
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
                records: records,
                endsAtVerifiedPrefix: sequence == scan.verifiedPrefixNextSequence
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
                acknowledgedPrefixEndOffset: endOffset,
                // Direct acknowledgement is retained for the lease API's existing
                // callers. It also establishes a materialized lower bound, because
                // an acknowledged record is necessarily fully durable.
                materializedPrefixNextSequence: max(cursor.materializedPrefixNextSequence, throughSequence + 1),
                materializedPrefixEndOffset: max(cursor.materializedPrefixEndOffset, endOffset),
                nextPartitionOrdinal: cursor.nextPartitionOrdinal,
                nextSampleOffset: cursor.nextSampleOffset,
                replayMarkerNextSequence: cursor.replayMarkerNextSequence
            )
            return self.writeCursor(next)
        } catch {
            return .refused(.cursorUnreadable)
        }
    }

    private func scanCurrent() -> OmiLaunchCaptureScanResult? {
        self.scanCurrent(from: OmiLaunchCaptureReadPosition(generationID: self.generationID, nextSequence: 0, offset: 0))
    }

    private func scanCurrent(from position: OmiLaunchCaptureReadPosition) -> OmiLaunchCaptureScanResult? {
        do {
            guard try self.io.fileExists(at: self.fileURL) else { return OmiLaunchCaptureScanResult() }
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            return OmiLaunchCaptureLogic.scan(
                generationID: self.generationID,
                fileSize: try self.io.fileSize(at: self.fileURL),
                startOffset: position.offset,
                expectedSequence: position.nextSequence,
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
            // Read one byte past the fixed format so a bounded read distinguishes short, exact, and extended cursor files.
            let data = try self.io.read(token, offset: 0, count: OmiLaunchCaptureCursorFormat.byteCount + 1)
            switch OmiLaunchCaptureCursor.decode(data) {
            case .success(let cursor):
                guard cursor.generationID == self.generationID else {
                    return .unreadable(self.makeCursorDefect(reason: .generationMismatch, bytes: data))
                }
                return .valid(cursor)
            case .failure(let reason):
                return .unreadable(self.makeCursorDefect(reason: reason, bytes: data))
            }
        } catch {
            return .unreadable(self.makeCursorDefect(reason: .readFailed, bytes: Data()))
        }
    }

    private func makeCursorDefect(reason: OmiLaunchCaptureCursorDefectReason, bytes: Data) -> OmiLaunchCaptureCursorDefect {
        OmiLaunchCaptureCursorDefect(reason: reason, contentDigest: OmiLaunchCaptureDigest.truncated(bytes))
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
