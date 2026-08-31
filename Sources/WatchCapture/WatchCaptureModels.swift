// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchCaptureTiming {
    static let segmentDurationSeconds: TimeInterval = 300
}

nonisolated enum WatchNoticeIdentifiers {
    static let lease = "app.solstone.swift.watch.audio-lease"
    static let notice = "app.solstone.swift.watch.audio-notice"
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
    var deliveredAt: Date? = nil

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

nonisolated enum WatchNotificationAuthorizationStatus: String, Codable, Equatable, Sendable {
    case notDetermined = "not-determined"
    case authorized
    case denied
    case provisional
    case ephemeral
}

nonisolated enum WatchNotificationAlertSetting: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case notSupported = "not-supported"
}

nonisolated enum WatchNotificationPresentationOption: Hashable, Sendable {
    case banner
    case list
}

nonisolated func watchNoticePresentationOptions() -> Set<WatchNotificationPresentationOption> {
    [.banner, .list]
}

nonisolated enum WatchWristAlertAssurance: String, Codable, Equatable, Sendable {
    case willTap = "will-tap"
    case alertsOff = "alerts-off"

    var line: String {
        switch self {
        case .willTap:
            SourceVocabulary.watchWristAlertWillTap
        case .alertsOff:
            SourceVocabulary.watchWristAlertsOff
        }
    }
}

nonisolated func watchWristAlertAssurance(
    authorization: WatchNotificationAuthorizationStatus,
    alertSetting: WatchNotificationAlertSetting
) -> WatchWristAlertAssurance? {
    switch authorization {
    case .notDetermined:
        return nil
    case .denied:
        return .alertsOff
    case .authorized, .provisional, .ephemeral:
        switch alertSetting {
        case .enabled:
            return .willTap
        case .disabled, .notSupported:
            return .alertsOff
        }
    }
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
    case notificationGrant = "notification-grant"
    case notificationSettings = "notification-settings"
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

nonisolated enum WatchNoticeDecision: Equatable, Sendable {
    case none
    case cancelLease
    case schedule(copy: WatchNoticeCopy)
    case cannotSchedule(settingsRoute: WatchCaptureSettingsRoute)
}

nonisolated extension WatchNoticeDecision {
    var historyRawValue: String {
        switch self {
        case .none:
            "none"
        case .cancelLease:
            "cancel-lease"
        case .schedule:
            "schedule"
        case .cannotSchedule:
            "cannot-schedule"
        }
    }
}

nonisolated func watchNoticeDecision(
    authorizationStatus: WatchNotificationAuthorizationStatus,
    alertSetting: WatchNotificationAlertSetting,
    disposition: WatchCaptureTerminalDisposition,
    reason: WatchCaptureTerminalReason,
    leaseArmed: Bool
) -> WatchNoticeDecision {
    guard let copy = WatchNoticeCopy(reason: reason, disposition: disposition) else {
        return leaseArmed ? .cancelLease : .none
    }

    switch watchWristAlertAssurance(authorization: authorizationStatus, alertSetting: alertSetting) {
    case .willTap:
        return .schedule(copy: copy)
    case .alertsOff:
        return .cannotSchedule(settingsRoute: .notificationSettings)
    case nil:
        return .cannotSchedule(settingsRoute: .notificationGrant)
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
    var noticeOwed: Bool
    var segmentsProduced: Int

    enum CodingKeys: String, CodingKey {
        case sessionID
        case startedAt
        case state
        case terminalReason
        case terminalDisposition
        case terminalAt
        case noticeOwed
        case segmentsProduced
    }

    init(
        sessionID: String,
        startedAt: Date,
        state: WatchCaptureSessionRecordState,
        terminalReason: WatchCaptureTerminalReason?,
        terminalDisposition: WatchCaptureTerminalDisposition?,
        terminalAt: Date?,
        noticeOwed: Bool,
        segmentsProduced: Int = 0
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.state = state
        self.terminalReason = terminalReason
        self.terminalDisposition = terminalDisposition
        self.terminalAt = terminalAt
        self.noticeOwed = noticeOwed
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
        self.noticeOwed = try container.decode(Bool.self, forKey: .noticeOwed)
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
    let isSessionRunning: Bool
    let sessionStartedAt: Date?
    let settingsRoute: WatchCaptureSettingsRoute?
    let startRefusalReason: WatchCaptureStartRefusalReason?
    let terminalReason: WatchCaptureTerminalReason?
    let terminalDisposition: WatchCaptureTerminalDisposition?
    let locationAdvisory: WatchCaptureLocationAdvisory?
    let persistenceAdvisory: WatchCapturePersistenceAdvisory?
    let wristAlertAssurance: WatchWristAlertAssurance?
    let lastVerifiedAudioAt: Date?

    init(
        status: WatchCaptureRuntimeStatus,
        queuedCount: Int,
        transferringCount: Int = 0,
        confirmingCount: Int = 0,
        handedOffCount: Int = 0,
        isSessionRunning: Bool = false,
        sessionStartedAt: Date? = nil,
        settingsRoute: WatchCaptureSettingsRoute? = nil,
        startRefusalReason: WatchCaptureStartRefusalReason? = nil,
        terminalReason: WatchCaptureTerminalReason? = nil,
        terminalDisposition: WatchCaptureTerminalDisposition? = nil,
        locationAdvisory: WatchCaptureLocationAdvisory? = nil,
        persistenceAdvisory: WatchCapturePersistenceAdvisory? = nil,
        wristAlertAssurance: WatchWristAlertAssurance? = nil,
        lastVerifiedAudioAt: Date? = nil
    ) {
        self.status = status
        self.queuedCount = queuedCount
        self.transferringCount = transferringCount
        self.confirmingCount = confirmingCount
        self.handedOffCount = handedOffCount
        self.isSessionRunning = isSessionRunning
        self.sessionStartedAt = sessionStartedAt
        self.settingsRoute = settingsRoute
        self.startRefusalReason = startRefusalReason
        self.terminalReason = terminalReason
        self.terminalDisposition = terminalDisposition
        self.locationAdvisory = locationAdvisory
        self.persistenceAdvisory = persistenceAdvisory
        self.wristAlertAssurance = wristAlertAssurance
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
