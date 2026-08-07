// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum OmiLaunchCaptureIngressInput: Equatable {
    case payload(Data)
    case streamError
    case invalidValue
}

@MainActor
enum OmiLaunchCaptureIngressBoundaryReason: String, Equatable {
    case streamError = "stream_error"
    case invalidValue = "invalid_value"
    case payloadNotRetained = "payload_not_retained"
    case payloadWriteFailed = "payload_write_failed"
    case recordTagWriteFailed = "record_tag_write_failed"
    case commitBarrierFailed = "commit_barrier_failed"
}

@MainActor
enum OmiLaunchCaptureIngressResult: Equatable {
    case retainedContiguous
    case boundaryCommitted(reason: OmiLaunchCaptureIngressBoundaryReason)
    case suffixRetainedNoncontiguous
    case notRetained
}

@MainActor
final class OmiLaunchCaptureIngress {
    private let appGroupRoot: () throws -> URL
    private var generationID: UUID
    private let clock: any ObserverClock
    private let io: any OmiLaunchCaptureIO
    private var writer: OmiLaunchCaptureWriter?
    private(set) var isLatched = false
    private(set) var hasCommittedBoundary = false
    private var didConsumeResume = false
    private(set) var didAttemptInitialArm = false

    var isArmed: Bool { self.writer != nil }
    var activeGenerationID: UUID { self.generationID }

    init(
        appGroupRoot: @escaping () throws -> URL,
        generationID: UUID = UUID(),
        clock: any ObserverClock = SystemObserverClock(),
        io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()
    ) {
        self.appGroupRoot = appGroupRoot
        self.generationID = generationID
        self.clock = clock
        self.io = io
    }

    func arm() -> Bool {
        guard self.writer == nil else { return true }
        self.didAttemptInitialArm = true
        guard let rootURL = try? self.appGroupRoot() else { return false }
        let writer = OmiLaunchCaptureWriter(
            rootURL: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true),
            generationID: self.generationID,
            clock: self.clock,
            io: self.io
        )
        guard writer.arm() else { return false }
        self.writer = writer
        return true
    }

    func armForFirstEnable() -> Bool {
        guard !self.didAttemptInitialArm else { return false }
        return self.arm()
    }

    func resumeOnce() -> Bool {
        guard !self.isArmed, !self.didConsumeResume else { return false }
        self.didConsumeResume = true
        return self.arm()
    }

    func ingest(_ input: OmiLaunchCaptureIngressInput) -> OmiLaunchCaptureIngressResult {
        guard let writer else {
            self.isLatched = true
            return .notRetained
        }
        switch input {
        case .payload(let payload):
            if self.isLatched, !self.hasCommittedBoundary {
                return self.routeReservation(writer.reserveGap(), reason: .payloadNotRetained)
            }
            return self.routeAppend(writer.append(payload), writer: writer)
        case .streamError:
            return self.routeReservation(writer.reserveGap(), reason: .streamError)
        case .invalidValue:
            return self.routeReservation(writer.reserveGap(), reason: .invalidValue)
        }
    }

    func rotateAfterCommittedBoundary() -> Bool {
        guard self.isLatched, self.hasCommittedBoundary,
              let rootURL = try? self.appGroupRoot()
        else {
            return false
        }
        let generationID = UUID()
        let candidate = OmiLaunchCaptureWriter(
            rootURL: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true),
            generationID: generationID,
            clock: self.clock,
            io: self.io
        )
        guard candidate.arm() else { return false }

        self.writer = candidate
        self.generationID = generationID
        self.isLatched = false
        self.hasCommittedBoundary = false
        return true
    }

    private func routeAppend(
        _ outcome: OmiLaunchCaptureAppendOutcome,
        writer: OmiLaunchCaptureWriter
    ) -> OmiLaunchCaptureIngressResult {
        switch outcome {
        case .retained:
            return self.isLatched ? .suffixRetainedNoncontiguous : .retainedContiguous
        case .notRetained:
            return self.routeReservation(writer.reserveGap(), reason: .payloadNotRetained)
        case .visibleGap(_, let reason):
            self.isLatched = true
            self.hasCommittedBoundary = true
            return .boundaryCommitted(reason: Self.boundaryReason(for: reason))
        case .rejected(let reason):
            if case .pendingSlotOccupied = reason {
                return self.routeReservation(writer.reserveGap(), reason: .payloadNotRetained)
            }
            self.isLatched = true
            return .notRetained
        }
    }

    private func routeReservation(
        _ outcome: OmiLaunchCaptureAppendOutcome,
        reason: OmiLaunchCaptureIngressBoundaryReason
    ) -> OmiLaunchCaptureIngressResult {
        switch outcome {
        case .visibleGap:
            self.isLatched = true
            self.hasCommittedBoundary = true
            return .boundaryCommitted(reason: reason)
        case .retained, .notRetained, .rejected:
            self.isLatched = true
            return .notRetained
        }
    }

    private static func boundaryReason(for reason: OmiLaunchCaptureGapReason) -> OmiLaunchCaptureIngressBoundaryReason {
        switch reason {
        case .payloadWriteFailed:
            .payloadWriteFailed
        case .recordTagWriteFailed:
            .recordTagWriteFailed
        case .commitBarrierFailed:
            .commitBarrierFailed
        case .intentionalGap:
            .payloadNotRetained
        }
    }
}
