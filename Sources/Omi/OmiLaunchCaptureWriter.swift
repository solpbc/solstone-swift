// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class OmiLaunchCaptureWriter {
    private struct PendingRecord {
        let sequence: UInt64
        let payload: Data
        let reservationOffset: Int
        let header: Data
    }

    private enum State {
        case unprepared
        case ready(nextSequence: UInt64, lastCommittedRecordEnd: Int)
        case blocked(reason: OmiLaunchCaptureBoundaryReason, offset: Int)
    }

    private let rootURL: URL
    private let generationID: UUID
    private let clock: any ObserverClock
    private let io: any OmiLaunchCaptureIO
    private var state: State = .unprepared
    private var pending: PendingRecord?
    private var inFlightPayloadBytes = 0
    private var pendingPayloadBytes = 0

    private(set) var captureResidentPayloadBytes = 0
    private(set) var peakCaptureResidentPayloadBytes = 0

    // append is intentionally synchronous: its two F_FULLFSYNC barriers make the returned outcome
    // reflect the durable protocol state. Calls assumed onto the main actor therefore wait for storage
    // latency. Moving barriers off the main actor is deferred because it must retain this ordering and
    // immediately typed outcome without introducing an unbounded payload queue.

    init(
        rootURL: URL,
        generationID: UUID = UUID(),
        clock: any ObserverClock = SystemObserverClock(),
        io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()
    ) {
        self.rootURL = rootURL
        self.generationID = generationID
        self.clock = clock
        self.io = io
    }

    var fileURL: URL {
        OmiLaunchCaptureFormat.fileURL(rootURL: self.rootURL, generationID: self.generationID)
    }

    func arm() -> Bool {
        self.prepareIfNeeded()
        guard case .ready = self.state else { return false }
        do {
            let token = try self.io.openOrCreateAppendFile(at: self.fileURL)
            try self.io.close(token)
            return true
        } catch {
            return false
        }
    }

    func append(_ payload: Data) -> OmiLaunchCaptureAppendOutcome {
        guard payload.count <= OmiLaunchCaptureFormat.maximumPayloadBytes else {
            return .notRetained(.oversizeActualLength)
        }
        self.beginInFlightPayload(payload)
        defer { self.clearInFlightPayload() }
        self.prepareIfNeeded()
        guard case .ready(_, let lastCommittedRecordEnd) = self.state else {
            return self.blockedOutcome()
        }

        var didRetryPending = false
        if let pending {
            switch self.retry(pending, lastCommittedRecordEnd: lastCommittedRecordEnd) {
            case .success(let committedEnd):
                self.clearPending()
                self.state = .ready(nextSequence: pending.sequence + 1, lastCommittedRecordEnd: committedEnd)
                didRetryPending = true
            case .failure(let reason):
                return .rejected(.pendingSlotOccupied(pendingSequence: pending.sequence, retryFailure: reason))
            }
        }

        guard case .ready(let sequence, let committedEnd) = self.state else {
            return self.blockedOutcome()
        }
        return self.appendNew(
            payload,
            sequence: sequence,
            lastCommittedRecordEnd: committedEnd,
            retriedPending: didRetryPending
        )
    }

    func reserveGap() -> OmiLaunchCaptureAppendOutcome {
        self.prepareIfNeeded()
        guard case .ready(_, let lastCommittedRecordEnd) = self.state else {
            return self.blockedOutcome()
        }

        // P must commit before Q reserves, so restart can never expose Q ahead of P's durable order.
        if let pending {
            switch self.retry(pending, lastCommittedRecordEnd: lastCommittedRecordEnd) {
            case .success(let committedEnd):
                self.clearPending()
                self.state = .ready(nextSequence: pending.sequence + 1, lastCommittedRecordEnd: committedEnd)
            case .failure(let reason):
                return .rejected(.pendingSlotOccupied(pendingSequence: pending.sequence, retryFailure: reason))
            }
        }

        guard case .ready(let sequence, let committedEnd) = self.state else {
            return self.blockedOutcome()
        }
        return self.reserveNewGap(sequence: sequence, lastCommittedRecordEnd: committedEnd)
    }

    private func prepareIfNeeded() {
        guard case .unprepared = self.state else { return }
        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: self.generationID, io: self.io).recover()
        if let reason = recovery.boundaryReason, let offset = recovery.boundaryOffset {
            // A recovery boundary blocks only this generation. A new generation file is independent.
            self.state = .blocked(reason: reason, offset: offset)
            return
        }
        self.state = .ready(
            nextSequence: recovery.verifiedPrefixNextSequence,
            lastCommittedRecordEnd: recovery.verifiedPrefixEndOffset
        )
    }

    private func appendNew(
        _ payload: Data,
        sequence: UInt64,
        lastCommittedRecordEnd: Int,
        retriedPending: Bool
    ) -> OmiLaunchCaptureAppendOutcome {
        let token: OmiLaunchCaptureFileToken
        do {
            token = try self.io.openOrCreateAppendFile(at: self.fileURL)
        } catch {
            return .notRetained(.openFailed)
        }
        defer { try? self.io.close(token) }

        let reservationOffset: Int
        do {
            reservationOffset = try self.io.fileSize(at: self.fileURL)
        } catch {
            return .notRetained(.openFailed)
        }
        let acquiredAtUnixMicros = OmiLaunchCaptureLogic.unixMicros(self.clock.now())
        let header = OmiLaunchCaptureHeader(
            generationID: self.generationID,
            sequence: sequence,
            acquiredAtUnixMicros: acquiredAtUnixMicros,
            declaredPayloadBytes: payload.count
        ).encoded()
        do {
            try self.io.append(header, to: token)
        } catch {
            self.discardPreReservationBytes(
                token,
                reservationOffset: reservationOffset,
                lastCommittedRecordEnd: lastCommittedRecordEnd
            )
            return .notRetained(.headerWriteFailed)
        }
        do {
            try self.io.fullSynchronize(token)
        } catch {
            self.discardPreReservationBytes(
                token,
                reservationOffset: reservationOffset,
                lastCommittedRecordEnd: lastCommittedRecordEnd
            )
            return .notRetained(.reservationBarrierFailed)
        }

        let pending = PendingRecord(
            sequence: sequence,
            payload: payload,
            reservationOffset: reservationOffset,
            header: header
        )
        self.setPending(pending)
        let outcome = self.writeCommittedBody(pending, to: token)
        switch outcome {
        case .success(let committedEnd):
            self.clearPending()
            self.state = .ready(nextSequence: sequence + 1, lastCommittedRecordEnd: committedEnd)
            return .retained(sequence: sequence, retriedPending: retriedPending)
        case .failure(let reason):
            return .visibleGap(sequence: sequence, reason)
        }
    }

    private func reserveNewGap(
        sequence: UInt64,
        lastCommittedRecordEnd: Int
    ) -> OmiLaunchCaptureAppendOutcome {
        let token: OmiLaunchCaptureFileToken
        do {
            token = try self.io.openOrCreateAppendFile(at: self.fileURL)
        } catch {
            return .notRetained(.openFailed)
        }
        defer { try? self.io.close(token) }

        let reservationOffset: Int
        do {
            reservationOffset = try self.io.fileSize(at: self.fileURL)
        } catch {
            return .notRetained(.openFailed)
        }
        let header = OmiLaunchCaptureHeader(
            generationID: self.generationID,
            sequence: sequence,
            acquiredAtUnixMicros: OmiLaunchCaptureLogic.unixMicros(self.clock.now()),
            declaredPayloadBytes: 0
        ).encoded()
        do {
            try self.io.append(header, to: token)
        } catch {
            self.discardPreReservationBytes(
                token,
                reservationOffset: reservationOffset,
                lastCommittedRecordEnd: lastCommittedRecordEnd
            )
            return .notRetained(.headerWriteFailed)
        }
        do {
            try self.io.fullSynchronize(token)
        } catch {
            self.discardPreReservationBytes(
                token,
                reservationOffset: reservationOffset,
                lastCommittedRecordEnd: lastCommittedRecordEnd
            )
            return .notRetained(.reservationBarrierFailed)
        }

        // The reservation barrier makes this exact offset authoritative after a restart.
        self.state = .blocked(reason: .incompleteReservedRecord, offset: reservationOffset)
        return .visibleGap(sequence: sequence, .intentionalGap)
    }

    private func retry(
        _ pending: PendingRecord,
        lastCommittedRecordEnd: Int
    ) -> Result<Int, OmiLaunchCaptureGapReason> {
        let token: OmiLaunchCaptureFileToken
        do {
            token = try self.io.openOrCreateAppendFile(at: self.fileURL)
        } catch {
            return .failure(.payloadWriteFailed)
        }
        defer { try? self.io.close(token) }

        guard case .ready = self.state,
              let currentPending = self.pending,
              currentPending.sequence == pending.sequence,
              currentPending.reservationOffset == pending.reservationOffset,
              currentPending.reservationOffset >= lastCommittedRecordEnd else {
            return .failure(.payloadWriteFailed)
        }
        do {
            // This retry cleanup targets this writer's own durable reservation and is never allowed
            // below the verified committed prefix.
            try self.io.truncate(token, to: currentPending.reservationOffset)
        } catch {
            return .failure(.payloadWriteFailed)
        }
        do {
            try self.io.append(pending.header, to: token)
            try self.io.fullSynchronize(token)
        } catch {
            return .failure(.payloadWriteFailed)
        }
        return self.writeCommittedBody(pending, to: token)
    }

    private func discardPreReservationBytes(
        _ token: OmiLaunchCaptureFileToken,
        reservationOffset: Int,
        lastCommittedRecordEnd: Int
    ) {
        guard case .ready(_, let currentLastCommittedRecordEnd) = self.state,
              currentLastCommittedRecordEnd == lastCommittedRecordEnd,
              reservationOffset >= lastCommittedRecordEnd else {
            self.state = .blocked(reason: .preReservationCleanupFailed, offset: reservationOffset)
            return
        }
        do {
            // This is the other shortening operation: no reservation barrier completed, so this writer's
            // own reservation offset is the committed prefix and removing partial framing preserves it.
            try self.io.truncate(token, to: reservationOffset)
        } catch {
            self.state = .blocked(reason: .preReservationCleanupFailed, offset: reservationOffset)
        }
    }

    private func writeCommittedBody(
        _ pending: PendingRecord,
        to token: OmiLaunchCaptureFileToken
    ) -> Result<Int, OmiLaunchCaptureGapReason> {
        do {
            try self.io.append(pending.payload, to: token)
        } catch {
            return .failure(.payloadWriteFailed)
        }
        do {
            try self.io.append(OmiLaunchCaptureDigest.recordTag(header: pending.header, payload: pending.payload), to: token)
        } catch {
            return .failure(.recordTagWriteFailed)
        }
        do {
            try self.io.fullSynchronize(token)
        } catch {
            return .failure(.commitBarrierFailed)
        }
        return .success(pending.reservationOffset + OmiLaunchCaptureFormat.headerByteCount + pending.payload.count + OmiLaunchCaptureFormat.recordTagByteCount)
    }

    private func setPending(_ pending: PendingRecord) {
        self.inFlightPayloadBytes = 0
        self.pending = pending
        self.pendingPayloadBytes = pending.payload.count
        self.updateCaptureResidentPayloadBytes()
    }

    private func clearPending() {
        self.pending = nil
        self.pendingPayloadBytes = 0
        self.updateCaptureResidentPayloadBytes()
    }

    private func beginInFlightPayload(_ payload: Data) {
        self.inFlightPayloadBytes = payload.count
        self.updateCaptureResidentPayloadBytes()
    }

    private func clearInFlightPayload() {
        self.inFlightPayloadBytes = 0
        self.updateCaptureResidentPayloadBytes()
    }

    private func updateCaptureResidentPayloadBytes() {
        self.captureResidentPayloadBytes = self.inFlightPayloadBytes + self.pendingPayloadBytes
        self.peakCaptureResidentPayloadBytes = max(self.peakCaptureResidentPayloadBytes, self.captureResidentPayloadBytes)
    }

    private func blockedOutcome() -> OmiLaunchCaptureAppendOutcome {
        guard case .blocked(let reason, let offset) = self.state else {
            return .notRetained(.openFailed)
        }
        return .rejected(.recoveryBoundary(reason: reason, offset: offset))
    }
}
