// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchCaptureTiming {
    static let segmentDurationSeconds: TimeInterval = 300
}

nonisolated enum WatchSegmentState: String, Codable, Equatable, Sendable, CaseIterable {
    case captured
    case persisted
    case finalized
    case queued
    case transferring
    case delivered
    case acked
    case safeToDelete
    case abandoned
}

nonisolated enum WatchSensor: String, Codable, Equatable, Sendable, CaseIterable {
    case audio
    case location
}

nonisolated protocol WatchCaptureZoneSource: Sendable {
    func currentTimeZone() throws -> TimeZone
}

nonisolated struct DeviceWatchCaptureZoneSource: WatchCaptureZoneSource {
    func currentTimeZone() throws -> TimeZone {
        let zone = TimeZone.current
        if TimeZone.knownTimeZoneIdentifiers.contains(zone.identifier),
           let fixed = TimeZone(identifier: zone.identifier) {
            return fixed
        }
        return TimeZone(secondsFromGMT: zone.secondsFromGMT()) ?? TimeZone(secondsFromGMT: 0)!
    }
}

nonisolated struct SegmentTimeZoneStamp: Equatable, Sendable {
    var tz: String?
    var utcOffsetSeconds: Int

    init(timeZone: TimeZone, startedAt: Date) {
        let identifier = timeZone.identifier
        self.tz = TimeZone.knownTimeZoneIdentifiers.contains(identifier) ? identifier : nil
        self.utcOffsetSeconds = timeZone.secondsFromGMT(for: startedAt)
    }
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
    var deliveredAt: Date? = nil
    var batteryLevel: Double? = nil
    var batteryState: String? = nil
    var lowPowerMode: Bool? = nil
    var powerSampledAt: Date? = nil
    var relayDeliveryAttemptCount: Int? = nil
    var relayLastProgress: Double? = nil
    var relayLastProgressAt: Date? = nil
    var relayDeliveryEffortSeconds: Double? = nil
    var abandonedAt: Date? = nil
    var tz: String? = nil
    var utcOffsetSeconds: Int? = nil
    /// Absent keys are a pre-field manifest; JSON null is a recorded snapshot with no zone.
    var zoneSnapshotRecorded: Bool = false

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
        case deliveredAt = "delivered_at"
        case batteryLevel = "battery_level"
        case batteryState = "battery_state"
        case lowPowerMode = "low_power_mode"
        case powerSampledAt = "power_sampled_at"
        case relayDeliveryAttemptCount = "relay_delivery_attempt_count"
        case relayLastProgress = "relay_last_progress"
        case relayLastProgressAt = "relay_last_progress_at"
        case relayDeliveryEffortSeconds = "relay_delivery_effort_seconds"
        case abandonedAt = "abandoned_at"
        case tz
        case utcOffsetSeconds = "utc_offset_seconds"
    }

    init(
        id: UUID,
        day: String,
        segment: String,
        startedAt: Date,
        duration: Double,
        sensors: [WatchSensor],
        partial: Bool,
        lost: Bool,
        gap: Bool,
        fixCount: Int,
        state: WatchSegmentState,
        failureReason: String? = nil,
        deliveredAt: Date? = nil,
        batteryLevel: Double? = nil,
        batteryState: String? = nil,
        lowPowerMode: Bool? = nil,
        powerSampledAt: Date? = nil,
        relayDeliveryAttemptCount: Int? = nil,
        relayLastProgress: Double? = nil,
        relayLastProgressAt: Date? = nil,
        relayDeliveryEffortSeconds: Double? = nil,
        abandonedAt: Date? = nil,
        tz: String? = nil,
        utcOffsetSeconds: Int? = nil,
        zoneSnapshotRecorded: Bool = false
    ) {
        self.id = id
        self.day = day
        self.segment = segment
        self.startedAt = startedAt
        self.duration = duration
        self.sensors = sensors
        self.partial = partial
        self.lost = lost
        self.gap = gap
        self.fixCount = fixCount
        self.state = state
        self.failureReason = failureReason
        self.deliveredAt = deliveredAt
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.powerSampledAt = powerSampledAt
        self.relayDeliveryAttemptCount = relayDeliveryAttemptCount
        self.relayLastProgress = relayLastProgress
        self.relayLastProgressAt = relayLastProgressAt
        self.relayDeliveryEffortSeconds = relayDeliveryEffortSeconds
        self.abandonedAt = abandonedAt
        self.tz = tz
        self.utcOffsetSeconds = utcOffsetSeconds
        self.zoneSnapshotRecorded = zoneSnapshotRecorded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.day = try container.decode(String.self, forKey: .day)
        self.segment = try container.decode(String.self, forKey: .segment)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.sensors = try container.decode([WatchSensor].self, forKey: .sensors)
        self.partial = try container.decode(Bool.self, forKey: .partial)
        self.lost = try container.decode(Bool.self, forKey: .lost)
        self.gap = try container.decode(Bool.self, forKey: .gap)
        self.fixCount = try container.decode(Int.self, forKey: .fixCount)
        self.state = try container.decode(WatchSegmentState.self, forKey: .state)
        self.failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        self.deliveredAt = try container.decodeIfPresent(Date.self, forKey: .deliveredAt)
        self.batteryLevel = try container.decodeIfPresent(Double.self, forKey: .batteryLevel)
        self.batteryState = try container.decodeIfPresent(String.self, forKey: .batteryState)
        self.lowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .lowPowerMode)
        self.powerSampledAt = try container.decodeIfPresent(Date.self, forKey: .powerSampledAt)
        self.relayDeliveryAttemptCount = try container.decodeIfPresent(Int.self, forKey: .relayDeliveryAttemptCount)
        self.relayLastProgress = try container.decodeIfPresent(Double.self, forKey: .relayLastProgress)
        self.relayLastProgressAt = try container.decodeIfPresent(Date.self, forKey: .relayLastProgressAt)
        self.relayDeliveryEffortSeconds = try container.decodeIfPresent(Double.self, forKey: .relayDeliveryEffortSeconds)
        self.abandonedAt = try container.decodeIfPresent(Date.self, forKey: .abandonedAt)
        self.zoneSnapshotRecorded = container.contains(.tz) || container.contains(.utcOffsetSeconds)
        self.tz = try container.decodeIfPresent(String.self, forKey: .tz)
        self.utcOffsetSeconds = try container.decodeIfPresent(Int.self, forKey: .utcOffsetSeconds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.day, forKey: .day)
        try container.encode(self.segment, forKey: .segment)
        try container.encode(self.startedAt, forKey: .startedAt)
        try container.encode(self.duration, forKey: .duration)
        try container.encode(self.sensors, forKey: .sensors)
        try container.encode(self.partial, forKey: .partial)
        try container.encode(self.lost, forKey: .lost)
        try container.encode(self.gap, forKey: .gap)
        try container.encode(self.fixCount, forKey: .fixCount)
        try container.encode(self.state, forKey: .state)
        try container.encodeIfPresent(self.failureReason, forKey: .failureReason)
        try container.encodeIfPresent(self.deliveredAt, forKey: .deliveredAt)
        try container.encodeIfPresent(self.batteryLevel, forKey: .batteryLevel)
        try container.encodeIfPresent(self.batteryState, forKey: .batteryState)
        try container.encodeIfPresent(self.lowPowerMode, forKey: .lowPowerMode)
        try container.encodeIfPresent(self.powerSampledAt, forKey: .powerSampledAt)
        try container.encodeIfPresent(self.relayDeliveryAttemptCount, forKey: .relayDeliveryAttemptCount)
        try container.encodeIfPresent(self.relayLastProgress, forKey: .relayLastProgress)
        try container.encodeIfPresent(self.relayLastProgressAt, forKey: .relayLastProgressAt)
        try container.encodeIfPresent(self.relayDeliveryEffortSeconds, forKey: .relayDeliveryEffortSeconds)
        try container.encodeIfPresent(self.abandonedAt, forKey: .abandonedAt)
        if self.zoneSnapshotRecorded && self.tz == nil && self.utcOffsetSeconds == nil {
            try container.encodeNil(forKey: .tz)
            try container.encodeNil(forKey: .utcOffsetSeconds)
        } else {
            try container.encodeIfPresent(self.tz, forKey: .tz)
            try container.encodeIfPresent(self.utcOffsetSeconds, forKey: .utcOffsetSeconds)
        }
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

nonisolated enum WatchMicrophonePermission: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

nonisolated enum WatchCaptureStartRefusalReason: String, Codable, Equatable, Sendable {
    case microphonePermissionDenied = "microphone-permission-denied"
    case microphonePermissionNotDetermined = "microphone-permission-not-determined"
    case audioArmFailed = "audio-arm-failed"
}

nonisolated enum WatchCaptureTerminalReason: String, Codable, Equatable, Sendable, CaseIterable {
    case ownerStopped = "owner-stopped"
    case microphonePermissionRevoked = "microphone-permission-revoked"
    case audioStartFailed = "audio-start-failed"
    case audioFinishUnsuccessful = "audio-finish-unsuccessful"
    case audioEncodeError = "audio-encode-error"
    case audioInterrupted = "audio-interrupted"
    case audioRouteUnavailable = "audio-route-unavailable"
    case audioMediaServicesLost = "audio-media-services-lost"
    case audioMediaServicesReset = "audio-media-services-reset"
    case audioRecorderStopped = "audio-recorder-stopped"
    case audioClockStalled = "audio-clock-stalled"
    case audioUndecodable = "audio-undecodable"
    case processExitedWhileActive = "process-exited-while-active"

    var observerError: ObserverError {
        switch self {
        case .ownerStopped:
            .unavailable(reason: SourceVocabulary.watchHeadlineOff)
        case .microphonePermissionRevoked, .audioRouteUnavailable, .audioStartFailed:
            .unavailable(reason: SourceVocabulary.watchMicrophoneUnavailable)
        case .audioUndecodable:
            .unavailable(reason: SourceVocabulary.watchAudioCouldNotBeSaved)
        case .processExitedWhileActive:
            .unavailable(reason: SourceVocabulary.watchAudioStoppedItself)
        case .audioFinishUnsuccessful,
             .audioEncodeError,
             .audioInterrupted,
             .audioMediaServicesLost,
             .audioMediaServicesReset,
             .audioRecorderStopped,
             .audioClockStalled:
            .unavailable(reason: SourceVocabulary.watchAudioStoppedItself)
        }
    }

    func observerError(disposition: WatchCaptureTerminalDisposition?) -> ObserverError {
        if disposition == .inferredStoppedItself {
            return .unavailable(reason: SourceVocabulary.watchNoticeAudioCouldNotBeConfirmedTitle)
        }
        return self.observerError
    }
}

nonisolated enum WatchCaptureTerminalDisposition: String, Codable, Equatable, Sendable {
    case ownerStopped = "owner-stopped"
    case detectedStoppedItself = "detected-stopped-itself"
    case inferredStoppedItself = "inferred-stopped-itself"
}

nonisolated enum WatchCapturePersistenceAdvisory: String, Codable, Equatable, Sendable {
    case sessionRecordWriteFailed = "session-record-write-failed"
    case sessionRecordUnreadable = "session-record-unreadable"
    case manifestCatalogPartial = "manifest-catalog-partial"
    case manifestCatalogUnavailable = "manifest-catalog-unavailable"

    var message: String {
        switch self {
        case .sessionRecordWriteFailed:
            SourceVocabulary.watchStatusSaveFailed
        case .sessionRecordUnreadable:
            SourceVocabulary.watchStatusUnreadable
        case .manifestCatalogPartial:
            SourceVocabulary.watchManifestCatalogPartial
        case .manifestCatalogUnavailable:
            SourceVocabulary.watchManifestScanFailed
        }
    }
}

nonisolated enum WatchCaptureLocationAdvisory: String, Codable, Equatable, Sendable {
    case authorizationLost = "authorization-lost"
    case writeFailed = "write-failed"
    case providerFailed = "provider-failed"

    var message: String {
        SourceVocabulary.watchLocationUnavailable
    }
}

nonisolated enum WatchCaptureSettingsRoute: String, Codable, Equatable, Sendable {
    case microphone
}

nonisolated enum WatchNoticeCopy: Equatable, Sendable, CaseIterable {
    case microphoneAccessNeeded
    case audioCouldNotStart
    case audioStoppedItself
    case audioCouldNotBeSaved
    case audioCouldNotBeConfirmed

    init?(reason: WatchCaptureTerminalReason, disposition: WatchCaptureTerminalDisposition) {
        if disposition == .ownerStopped {
            return nil
        }
        if disposition == .inferredStoppedItself {
            self = .audioCouldNotBeConfirmed
            return
        }

        switch reason {
        case .ownerStopped:
            return nil
        case .microphonePermissionRevoked:
            self = .microphoneAccessNeeded
        case .audioStartFailed, .audioRouteUnavailable:
            self = .audioCouldNotStart
        case .audioFinishUnsuccessful,
             .audioEncodeError,
             .audioInterrupted,
             .audioMediaServicesLost,
             .audioMediaServicesReset,
             .audioRecorderStopped,
             .audioClockStalled:
            self = .audioStoppedItself
        case .audioUndecodable:
            self = .audioCouldNotBeSaved
        case .processExitedWhileActive:
            self = .audioCouldNotBeConfirmed
        }
    }

    init?(
        terminalReason: WatchCaptureTerminalReason?,
        terminalDisposition: WatchCaptureTerminalDisposition?
    ) {
        switch (terminalReason, terminalDisposition) {
        case (nil, nil):
            return nil
        case (_, .ownerStopped):
            return nil
        case let (reason?, disposition?):
            self = WatchNoticeCopy(reason: reason, disposition: disposition) ?? .audioCouldNotBeConfirmed
        default:
            self = .audioCouldNotBeConfirmed
        }
    }

    var title: String {
        switch self {
        case .microphoneAccessNeeded:
            SourceVocabulary.watchNoticeMicrophoneAccessTitle
        case .audioCouldNotStart:
            SourceVocabulary.watchNoticeAudioCouldNotStartTitle
        case .audioStoppedItself:
            SourceVocabulary.watchNoticeAudioStoppedTitle
        case .audioCouldNotBeSaved:
            SourceVocabulary.watchNoticeAudioCouldNotBeSavedTitle
        case .audioCouldNotBeConfirmed:
            SourceVocabulary.watchNoticeAudioCouldNotBeConfirmedTitle
        }
    }

    var body: String {
        switch self {
        case .microphoneAccessNeeded:
            SourceVocabulary.watchNoticeMicrophoneAccessBody
        case .audioCouldNotStart:
            SourceVocabulary.watchNoticeAudioCouldNotStartBody
        case .audioStoppedItself:
            SourceVocabulary.watchNoticeAudioStoppedBody
        case .audioCouldNotBeSaved:
            SourceVocabulary.watchNoticeAudioCouldNotBeSavedBody
        case .audioCouldNotBeConfirmed:
            SourceVocabulary.watchNoticeAudioCouldNotBeConfirmedBody
        }
    }

    var isDetectedCopy: Bool {
        switch self {
        case .microphoneAccessNeeded,
             .audioCouldNotStart,
             .audioStoppedItself,
             .audioCouldNotBeSaved:
            true
        case .audioCouldNotBeConfirmed:
            false
        }
    }
}

nonisolated enum WatchCaptureSessionRecordState: String, Codable, Equatable, Sendable {
    case active
    case terminal
}

nonisolated struct WatchCaptureSessionRecord: Codable, Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    var state: WatchCaptureSessionRecordState
    var terminalReason: WatchCaptureTerminalReason?
    var terminalDisposition: WatchCaptureTerminalDisposition?
    var terminalAt: Date?
    var segmentsProduced: Int

    enum CodingKeys: String, CodingKey {
        case sessionID
        case startedAt
        case state
        case terminalReason
        case terminalDisposition
        case terminalAt
        case segmentsProduced
    }

    init(
        sessionID: String,
        startedAt: Date,
        state: WatchCaptureSessionRecordState,
        terminalReason: WatchCaptureTerminalReason?,
        terminalDisposition: WatchCaptureTerminalDisposition?,
        terminalAt: Date?,
        segmentsProduced: Int = 0
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.state = state
        self.terminalReason = terminalReason
        self.terminalDisposition = terminalDisposition
        self.terminalAt = terminalAt
        self.segmentsProduced = segmentsProduced
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.state = try container.decode(WatchCaptureSessionRecordState.self, forKey: .state)
        self.terminalReason = try container.decodeIfPresent(WatchCaptureTerminalReason.self, forKey: .terminalReason)
        self.terminalDisposition = try container.decodeIfPresent(WatchCaptureTerminalDisposition.self, forKey: .terminalDisposition)
        self.terminalAt = try container.decodeIfPresent(Date.self, forKey: .terminalAt)
        self.segmentsProduced = try container.decodeIfPresent(Int.self, forKey: .segmentsProduced) ?? 0
    }
}

nonisolated enum WatchCaptureRuntimeStatus: Equatable, Sendable {
    case off
    case enrolling
    case active
    case needsAttention(ObserverError)
}

nonisolated struct WatchCaptureOwnerPresentation: Equatable, Sendable {
    let status: WatchCaptureRuntimeStatus
    let queuedCount: Int
    let transferringCount: Int
    let confirmingCount: Int
    let handedOffCount: Int
    let abandonedCount: Int
    let isSessionRunning: Bool
    let sessionStartedAt: Date?
    let settingsRoute: WatchCaptureSettingsRoute?
    let startRefusalReason: WatchCaptureStartRefusalReason?
    let terminalReason: WatchCaptureTerminalReason?
    let terminalDisposition: WatchCaptureTerminalDisposition?
    let locationAdvisory: WatchCaptureLocationAdvisory?
    let persistenceAdvisory: WatchCapturePersistenceAdvisory?
    let lastVerifiedAudioAt: Date?

    init(
        status: WatchCaptureRuntimeStatus,
        queuedCount: Int,
        transferringCount: Int = 0,
        confirmingCount: Int = 0,
        handedOffCount: Int = 0,
        abandonedCount: Int = 0,
        isSessionRunning: Bool = false,
        sessionStartedAt: Date? = nil,
        settingsRoute: WatchCaptureSettingsRoute? = nil,
        startRefusalReason: WatchCaptureStartRefusalReason? = nil,
        terminalReason: WatchCaptureTerminalReason? = nil,
        terminalDisposition: WatchCaptureTerminalDisposition? = nil,
        locationAdvisory: WatchCaptureLocationAdvisory? = nil,
        persistenceAdvisory: WatchCapturePersistenceAdvisory? = nil,
        lastVerifiedAudioAt: Date? = nil
    ) {
        self.status = status
        self.queuedCount = queuedCount
        self.transferringCount = transferringCount
        self.confirmingCount = confirmingCount
        self.handedOffCount = handedOffCount
        self.abandonedCount = abandonedCount
        self.isSessionRunning = isSessionRunning
        self.sessionStartedAt = sessionStartedAt
        self.settingsRoute = settingsRoute
        self.startRefusalReason = startRefusalReason
        self.terminalReason = terminalReason
        self.terminalDisposition = terminalDisposition
        self.locationAdvisory = locationAdvisory
        self.persistenceAdvisory = persistenceAdvisory
        self.lastVerifiedAudioAt = lastVerifiedAudioAt
    }

    var headline: String {
        switch self.status {
        case .needsAttention(let error):
            return error.message
        case .enrolling:
            return SourceVocabulary.watchHeadlineEnrolling
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
            if self.confirmingCount > 0 {
                return SourceVocabulary.watchPipelineConfirming
            }
            if self.abandonedCount > 0 {
                return SourceVocabulary.watchPipelineAbandoned
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
        if self.confirmingCount > 0 {
            parts.append(SourceVocabulary.watchConfirmingCount(self.confirmingCount))
        }
        if self.abandonedCount > 0 {
            parts.append(SourceVocabulary.watchAbandonedCount(self.abandonedCount))
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
        if let persistenceAdvisory {
            return persistenceAdvisory.message
        }
        if let locationAdvisory {
            return locationAdvisory.message
        }
        return nil
    }
}

nonisolated enum WatchCaptureFailureMapper {
    static func observerError(for error: any Error) -> ObserverError {
        if let observerError = error as? ObserverError { return observerError }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return .diskFull
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        return .unavailable(reason: SourceVocabulary.watchGenericUnavailable)
    }
}
