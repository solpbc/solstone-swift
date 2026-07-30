// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchComplicationMark: String, CaseIterable, Codable, Equatable, Sendable {
    case sun
    case cloud
    case bang
}

nonisolated struct WatchComplicationSnapshot: Codable, Equatable, Sendable {
    static let widgetKind = "SolstoneWatchStatus"
    static let fileName = "watch-complication-snapshot.json"

    let stateWord: String
    let role: WatchFaceColorRole
    let mark: WatchComplicationMark
    let showsElapsed: Bool
    let sessionStartedAt: Date?
    let handoffLine: String?
    let handoffSubtext: String?
    let handoffRole: WatchFaceColorRole?
    let trustLine: String?
    let lastVerifiedAudioAt: Date?

    init(
        stateWord: String,
        role: WatchFaceColorRole,
        mark: WatchComplicationMark,
        showsElapsed: Bool,
        sessionStartedAt: Date?,
        handoffLine: String?,
        handoffSubtext: String?,
        handoffRole: WatchFaceColorRole?,
        trustLine: String?,
        lastVerifiedAudioAt: Date? = nil
    ) {
        self.stateWord = stateWord
        self.role = role
        self.mark = mark
        self.showsElapsed = showsElapsed
        self.sessionStartedAt = sessionStartedAt
        self.handoffLine = handoffLine
        self.handoffSubtext = handoffSubtext
        self.handoffRole = handoffRole
        self.trustLine = trustLine
        self.lastVerifiedAudioAt = lastVerifiedAudioAt
    }

    init(presentation: WatchCaptureOwnerPresentation, isReachable: Bool) {
        let model = watchFaceModel(for: presentation, isReachable: isReachable)
        self.init(
            stateWord: model.stateWord,
            role: model.stateColorRole,
            mark: Self.mark(for: presentation.status),
            showsElapsed: model.showsElapsed,
            sessionStartedAt: presentation.sessionStartedAt,
            handoffLine: model.compactHandoff?.line,
            handoffSubtext: model.compactHandoff?.subtext,
            handoffRole: model.compactHandoff?.role,
            trustLine: model.trustLine,
            lastVerifiedAudioAt: presentation.lastVerifiedAudioAt
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(WatchFaceColorRole.self, forKey: .role)

        self.stateWord = try container.decode(String.self, forKey: .stateWord)
        self.role = role
        self.mark = try container.decodeIfPresent(WatchComplicationMark.self, forKey: .mark)
            ?? Self.mark(forLegacyRole: role)
        self.showsElapsed = try container.decode(Bool.self, forKey: .showsElapsed)
        self.sessionStartedAt = try container.decodeIfPresent(Date.self, forKey: .sessionStartedAt)
        self.handoffLine = try container.decodeIfPresent(String.self, forKey: .handoffLine)
        self.handoffSubtext = try container.decodeIfPresent(String.self, forKey: .handoffSubtext)
        self.handoffRole = try container.decodeIfPresent(WatchFaceColorRole.self, forKey: .handoffRole)
        self.trustLine = try container.decodeIfPresent(String.self, forKey: .trustLine)
        self.lastVerifiedAudioAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAudioAt)
    }
}

nonisolated struct WatchComplicationTimelinePoint: Equatable, Sendable {
    let date: Date
    let snapshot: WatchComplicationSnapshot?
}

nonisolated func watchComplicationTimelinePoints(
    snapshot: WatchComplicationSnapshot?,
    now: Date,
    segmentDurationSeconds: TimeInterval = WatchCaptureTiming.segmentDurationSeconds
) -> [WatchComplicationTimelinePoint] {
    guard let snapshot else {
        return [WatchComplicationTimelinePoint(date: now, snapshot: nil)]
    }
    guard snapshot.showsElapsed else {
        return [WatchComplicationTimelinePoint(date: now, snapshot: snapshot)]
    }
    guard let lastVerifiedAudioAt = snapshot.lastVerifiedAudioAt else {
        return [WatchComplicationTimelinePoint(date: now, snapshot: nil)]
    }

    let unconfirmedAt = lastVerifiedAudioAt.addingTimeInterval(segmentDurationSeconds * 2)
    guard now < unconfirmedAt else {
        return [WatchComplicationTimelinePoint(date: now, snapshot: nil)]
    }
    return [
        WatchComplicationTimelinePoint(date: now, snapshot: snapshot),
        WatchComplicationTimelinePoint(date: unconfirmedAt, snapshot: nil),
    ]
}

private extension WatchComplicationSnapshot {
    nonisolated static func mark(for status: WatchCaptureRuntimeStatus) -> WatchComplicationMark {
        switch status {
        case .active:
            .sun
        case .off, .enrolling:
            .cloud
        case .needsAttention:
            .bang
        }
    }

    nonisolated static func mark(forLegacyRole role: WatchFaceColorRole) -> WatchComplicationMark {
        switch role {
        case .live:
            .sun
        case .calm, .flight:
            .cloud
        case .alert:
            .bang
        }
    }
}

nonisolated func watchComplicationMarkAssetName(for snapshot: WatchComplicationSnapshot?) -> String {
    guard let snapshot else {
        return "SolRingQuestion"
    }

    switch snapshot.mark {
    case .sun:
        return "SolRingSun"
    case .cloud:
        return "SolRingCloud"
    case .bang:
        return "SolRingBang"
    }
}

nonisolated func watchComplicationInlineText(for snapshot: WatchComplicationSnapshot?) -> String {
    guard let snapshot else {
        return "sol · \(SourceVocabulary.watchComplicationUnknownInline)"
    }
    return "sol · \(snapshot.handoffLine ?? snapshot.stateWord)"
}
