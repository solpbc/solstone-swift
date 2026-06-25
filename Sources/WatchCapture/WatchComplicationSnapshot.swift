// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchComplicationSnapshot: Codable, Equatable, Sendable {
    static let widgetKind = "SolstoneWatchStatus"
    static let fileName = "watch-complication-snapshot.json"

    let stateWord: String
    let role: WatchFaceColorRole
    let showsElapsed: Bool
    let sessionStartedAt: Date?
    let handoffLine: String?
    let handoffSubtext: String?
    let handoffRole: WatchFaceColorRole?
    let trustLine: String?

    init(
        stateWord: String,
        role: WatchFaceColorRole,
        showsElapsed: Bool,
        sessionStartedAt: Date?,
        handoffLine: String?,
        handoffSubtext: String?,
        handoffRole: WatchFaceColorRole?,
        trustLine: String?
    ) {
        self.stateWord = stateWord
        self.role = role
        self.showsElapsed = showsElapsed
        self.sessionStartedAt = sessionStartedAt
        self.handoffLine = handoffLine
        self.handoffSubtext = handoffSubtext
        self.handoffRole = handoffRole
        self.trustLine = trustLine
    }

    init(presentation: WatchCaptureOwnerPresentation, isReachable: Bool) {
        let model = watchFaceModel(for: presentation, isReachable: isReachable)
        self.init(
            stateWord: model.stateWord,
            role: model.stateColorRole,
            showsElapsed: model.showsElapsed,
            sessionStartedAt: presentation.sessionStartedAt,
            handoffLine: model.compactHandoff?.line,
            handoffSubtext: model.compactHandoff?.subtext,
            handoffRole: model.compactHandoff?.role,
            trustLine: model.trustLine
        )
    }
}
