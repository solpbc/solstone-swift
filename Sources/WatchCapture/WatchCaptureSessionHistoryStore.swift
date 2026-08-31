// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchCaptureLivenessEvidence: Codable, Equatable, Sendable {
    let audioCurrentTime: Double?
    let zeroAudioCurrentTimeObservationCount: Int?
}

nonisolated struct WatchCaptureSessionHistoryEntry: Codable, Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    var terminalAt: Date?
    var terminalReason: WatchCaptureTerminalReason?
    var terminalDisposition: WatchCaptureTerminalDisposition?
    var startRefusalReason: WatchCaptureStartRefusalReason?
    var settingsRoute: WatchCaptureSettingsRoute?
    var noticeOwed: Bool
    var noticeDecision: String?
    var noticeDelivered: Bool?
    var notificationAuthorizationStatus: WatchNotificationAuthorizationStatus?
    var notificationAlertSetting: WatchNotificationAlertSetting?
    var wristAlertAssurance: WatchWristAlertAssurance?
    var audioArmed: Bool
    var audioSessionIsActive: Bool
    var locationArmed: Bool
    var segmentsProduced: Int
    var batteryLevelAtEnd: Double?
    var batteryStateAtEnd: String?
    var lowPowerModeEnabledAtEnd: Bool?
    var thermalStateAtEnd: String?
    var lastVerifiedAudioAt: Date?
    var lastAudioCurrentTime: Double?
    var zeroAudioCurrentTimeObservationCount: Int?
    var locationAdvisory: WatchCaptureLocationAdvisory?
    var persistenceAdvisory: WatchCapturePersistenceAdvisory?

    enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case startedAt = "sa"
        case terminalAt = "ta"
        case terminalReason = "tr"
        case terminalDisposition = "td"
        case startRefusalReason = "sr"
        case settingsRoute = "rt"
        case noticeOwed = "no"
        case noticeDecision = "nd"
        case noticeDelivered = "dl"
        case notificationAuthorizationStatus = "na"
        case notificationAlertSetting = "ns"
        case wristAlertAssurance = "wa"
        case audioArmed = "aa"
        case audioSessionIsActive = "as"
        case locationArmed = "la"
        case segmentsProduced = "sp"
        case batteryLevelAtEnd = "bl"
        case batteryStateAtEnd = "bs"
        case lowPowerModeEnabledAtEnd = "lp"
        case thermalStateAtEnd = "th"
        case lastVerifiedAudioAt = "lv"
        case lastAudioCurrentTime = "ac"
        case zeroAudioCurrentTimeObservationCount = "zc"
        case locationAdvisory = "lo"
        case persistenceAdvisory = "pe"
    }

    var isComplete: Bool {
        self.terminalAt != nil || self.startRefusalReason != nil
    }
}

nonisolated struct WatchCaptureSessionHistoryCounter: Codable, Equatable, Sendable {
    let epoch: String
    let lifetimeSessionsStarted: Int
}

nonisolated enum WatchCaptureSessionHistoryReadResult: Equatable, Sendable {
    case available([WatchCaptureSessionHistoryEntry])
    case unreadable
}
