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
    var lastObservedAt: Date? = nil
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
        case lastObservedAt = "oa"
        case locationAdvisory = "lo"
        case persistenceAdvisory = "pe"
    }

    init(
        sessionID: String,
        startedAt: Date,
        terminalAt: Date?,
        terminalReason: WatchCaptureTerminalReason?,
        terminalDisposition: WatchCaptureTerminalDisposition?,
        startRefusalReason: WatchCaptureStartRefusalReason?,
        settingsRoute: WatchCaptureSettingsRoute?,
        audioArmed: Bool,
        audioSessionIsActive: Bool,
        locationArmed: Bool,
        segmentsProduced: Int,
        batteryLevelAtEnd: Double?,
        batteryStateAtEnd: String?,
        lowPowerModeEnabledAtEnd: Bool?,
        thermalStateAtEnd: String?,
        lastVerifiedAudioAt: Date?,
        lastAudioCurrentTime: Double?,
        zeroAudioCurrentTimeObservationCount: Int?,
        lastObservedAt: Date? = nil,
        locationAdvisory: WatchCaptureLocationAdvisory?,
        persistenceAdvisory: WatchCapturePersistenceAdvisory?
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.terminalAt = terminalAt
        self.terminalReason = terminalReason
        self.terminalDisposition = terminalDisposition
        self.startRefusalReason = startRefusalReason
        self.settingsRoute = settingsRoute
        self.audioArmed = audioArmed
        self.audioSessionIsActive = audioSessionIsActive
        self.locationArmed = locationArmed
        self.segmentsProduced = segmentsProduced
        self.batteryLevelAtEnd = batteryLevelAtEnd
        self.batteryStateAtEnd = batteryStateAtEnd
        self.lowPowerModeEnabledAtEnd = lowPowerModeEnabledAtEnd
        self.thermalStateAtEnd = thermalStateAtEnd
        self.lastVerifiedAudioAt = lastVerifiedAudioAt
        self.lastAudioCurrentTime = lastAudioCurrentTime
        self.zeroAudioCurrentTimeObservationCount = zeroAudioCurrentTimeObservationCount
        self.lastObservedAt = lastObservedAt
        self.locationAdvisory = locationAdvisory
        self.persistenceAdvisory = persistenceAdvisory
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.terminalAt = try container.decodeIfPresent(Date.self, forKey: .terminalAt)
        self.terminalReason = try container.decodeIfPresent(WatchCaptureTerminalReason.self, forKey: .terminalReason)
        self.terminalDisposition = try container.decodeIfPresent(WatchCaptureTerminalDisposition.self, forKey: .terminalDisposition)
        self.startRefusalReason = try container.decodeIfPresent(WatchCaptureStartRefusalReason.self, forKey: .startRefusalReason)
        let settingsRouteRawValue = try container.decodeIfPresent(String.self, forKey: .settingsRoute)
        self.settingsRoute = settingsRouteRawValue.flatMap(WatchCaptureSettingsRoute.init(rawValue:))
        self.audioArmed = try container.decode(Bool.self, forKey: .audioArmed)
        self.audioSessionIsActive = try container.decode(Bool.self, forKey: .audioSessionIsActive)
        self.locationArmed = try container.decode(Bool.self, forKey: .locationArmed)
        self.segmentsProduced = try container.decode(Int.self, forKey: .segmentsProduced)
        self.batteryLevelAtEnd = try container.decodeIfPresent(Double.self, forKey: .batteryLevelAtEnd)
        self.batteryStateAtEnd = try container.decodeIfPresent(String.self, forKey: .batteryStateAtEnd)
        self.lowPowerModeEnabledAtEnd = try container.decodeIfPresent(Bool.self, forKey: .lowPowerModeEnabledAtEnd)
        self.thermalStateAtEnd = try container.decodeIfPresent(String.self, forKey: .thermalStateAtEnd)
        self.lastVerifiedAudioAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAudioAt)
        self.lastAudioCurrentTime = try container.decodeIfPresent(Double.self, forKey: .lastAudioCurrentTime)
        self.zeroAudioCurrentTimeObservationCount = try container.decodeIfPresent(Int.self, forKey: .zeroAudioCurrentTimeObservationCount)
        self.lastObservedAt = try container.decodeIfPresent(Date.self, forKey: .lastObservedAt)
        self.locationAdvisory = try container.decodeIfPresent(WatchCaptureLocationAdvisory.self, forKey: .locationAdvisory)
        self.persistenceAdvisory = try container.decodeIfPresent(WatchCapturePersistenceAdvisory.self, forKey: .persistenceAdvisory)
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
