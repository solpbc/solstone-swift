// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchSegmentState: String, Codable, Equatable, Sendable, CaseIterable {
    case captured
    case persisted
    case finalized
    case queued
    case transferring
    case delivered
    case acked
    case safeToDelete
}

nonisolated enum WatchSensor: String, Codable, Equatable, Sendable, CaseIterable {
    case audio
    case location
}

nonisolated struct WatchSegmentManifest: Codable, Equatable, Sendable {
    let id: UUID
    var day: String
    var segment: String
    var startedAt: Date
    var duration: Double
    var sensors: [WatchSensor]
    var partial: Bool
    var lost: Bool
    var gap: Bool
    var fixCount: Int
    var state: WatchSegmentState
    var failureReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case day
        case segment
        case startedAt = "started_at"
        case duration
        case sensors
        case partial
        case lost
        case gap
        case fixCount = "fix_count"
        case state
        case failureReason = "failure_reason"
    }
}

nonisolated struct WatchLocationFix: Equatable, Sendable {
    let t: Date
    let lat: Double
    let lon: Double
    let hAcc: Double
    let alt: Double?
    let vAcc: Double?
    let speed: Double?
    let course: Double?
    let stationary: Bool

    func carryForward(at date: Date) -> WatchLocationFix {
        WatchLocationFix(
            t: date,
            lat: self.lat,
            lon: self.lon,
            hAcc: self.hAcc,
            alt: self.alt,
            vAcc: self.vAcc,
            speed: self.speed,
            course: self.course,
            stationary: true
        )
    }
}

nonisolated enum WatchLocationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

nonisolated enum WatchCaptureRuntimeStatus: Equatable, Sendable {
    case off
    case enrolling
    case active
    case paused
    case needsAttention(ObserverError)

    var needsAttention: Bool {
        if case .needsAttention = self {
            return true
        }
        return false
    }
}

nonisolated struct WatchCaptureOwnerPresentation: Equatable, Sendable {
    let status: WatchCaptureRuntimeStatus
    let queuedCount: Int
    let transferringCount: Int
    let handedOffCount: Int
    let isSessionRunning: Bool
    let sessionStartedAt: Date?

    init(
        status: WatchCaptureRuntimeStatus,
        queuedCount: Int,
        transferringCount: Int = 0,
        handedOffCount: Int = 0,
        isSessionRunning: Bool = false,
        sessionStartedAt: Date? = nil
    ) {
        self.status = status
        self.queuedCount = queuedCount
        self.transferringCount = transferringCount
        self.handedOffCount = handedOffCount
        self.isSessionRunning = isSessionRunning
        self.sessionStartedAt = sessionStartedAt
    }

    var headline: String {
        switch self.status {
        case .needsAttention(let error):
            return error.message
        case .enrolling:
            return SourceVocabulary.watchHeadlineEnrolling
        case .paused:
            return SourceVocabulary.watchHeadlinePaused
        case .active:
            return SourceVocabulary.watchHeadlineListening
        case .off:
            if self.isSessionRunning {
                return SourceVocabulary.watchHeadlineListening
            }
            if self.transferringCount > 0 {
                return SourceVocabulary.watchPipelineSending
            }
            if self.queuedCount > 0 {
                return SourceVocabulary.watchPipelineSaved
            }
            if self.handedOffCount > 0 {
                return SourceVocabulary.watchPipelineHandedOff
            }
            return SourceVocabulary.watchHeadlineOff
        }
    }

    var countsLine: String? {
        var parts: [String] = []
        if self.transferringCount > 0 {
            parts.append(SourceVocabulary.watchSendingCount(self.transferringCount))
        }
        if self.queuedCount > 0 {
            parts.append(SourceVocabulary.watchSavedOnWatchCount(self.queuedCount))
        }
        if self.handedOffCount > 0 {
            parts.append(SourceVocabulary.watchHandedToPhoneCount(self.handedOffCount))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    var attentionLine: String? {
        if case .needsAttention(let error) = self.status {
            return error.message
        }
        return nil
    }
}

nonisolated enum WatchCaptureFailureMapper {
    static func observerError(for error: any Error) -> ObserverError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return .diskFull
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        return .unavailable(reason: String(describing: error))
    }
}
