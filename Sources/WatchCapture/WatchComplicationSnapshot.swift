// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchComplicationMark: String, CaseIterable, Codable, Equatable, Sendable {
    case healthy
    case attention
    case paused
    case connecting

    // Legacy on-disk bytes from the sun/cloud/bang vocabulary. Shipped watches
    // still hold those strings. decodeIfPresent throws on an unrecognized raw
    // value and the loader would then render the offline mark. Delete these
    // three alias arms once the fleet no longer writes or holds sun, cloud, or bang.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "healthy", "sun":
            self = .healthy
        case "attention", "bang":
            self = .attention
        case "paused", "cloud":
            self = .paused
        case "connecting":
            self = .connecting
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "unrecognized watch complication mark: \(raw)"
                )
            )
        }
    }
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
            .healthy
        case .off:
            .paused
        case .enrolling:
            .connecting
        case .needsAttention:
            .attention
        }
    }

    nonisolated static func mark(forLegacyRole role: WatchFaceColorRole) -> WatchComplicationMark {
        switch role {
        case .live:
            .healthy
        case .calm, .flight:
            .paused
        case .alert:
            .attention
        }
    }
}

nonisolated func watchComplicationMarkAssetName(for snapshot: WatchComplicationSnapshot?) -> String {
    guard let snapshot else {
        return "MarkOffline"
    }

    switch snapshot.mark {
    case .healthy:
        return "MarkHealthy"
    case .attention:
        return "MarkAttention"
    case .paused:
        return "MarkPaused"
    case .connecting:
        return "MarkConnecting"
    }
}

nonisolated func watchComplicationInlineText(for snapshot: WatchComplicationSnapshot?) -> String {
    guard let snapshot else {
        return "solstone · \(SourceVocabulary.watchComplicationUnknownInline)"
    }
    return "solstone · \(snapshot.handoffLine ?? snapshot.stateWord)"
}
