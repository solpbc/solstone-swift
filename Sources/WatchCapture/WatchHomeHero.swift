// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchHomeHero: Equatable, Sendable {
    var title: String
    var titleHex: String
    var titleIsLarge: Bool
    var titleLineLimit: Int
    var elapsedDisplay: String?
    var elapsedHex: String
    var spokenElapsed: String?
    var handoffLineHex: String?
    var linkLine: String
    var linkHex: String
    var handoffSubtextHex: String
}

nonisolated func watchHomeHero(
    model: WatchFaceModel,
    status: WatchCaptureRuntimeStatus,
    sessionStartedAt: Date?,
    now: Date
) -> WatchHomeHero {
    let title = model.stateWord
    let linkLine = model.linkLine
    let linkHex = WatchHomePalette.calm
    let handoffSubtextHex = WatchHomePalette.calm
    let elapsedHex = WatchHomePalette.cream
    let handoffLineHex = model.compactHandoff.map { WatchHomePalette.hex(for: $0.role) }

    switch status {
    case .active:
        if let sessionStartedAt {
            let seconds = max(0, Int(now.timeIntervalSince(sessionStartedAt)))
            return WatchHomeHero(
                title: title,
                titleHex: WatchHomePalette.liveText,
                titleIsLarge: false,
                titleLineLimit: 1,
                elapsedDisplay: watchElapsedDisplay(seconds: seconds),
                elapsedHex: elapsedHex,
                spokenElapsed: watchElapsedSpoken(seconds: seconds),
                handoffLineHex: handoffLineHex,
                linkLine: linkLine,
                linkHex: linkHex,
                handoffSubtextHex: handoffSubtextHex
            )
        } else {
            return WatchHomeHero(
                title: title,
                titleHex: WatchHomePalette.liveText,
                titleIsLarge: true,
                titleLineLimit: 1,
                elapsedDisplay: nil,
                elapsedHex: elapsedHex,
                spokenElapsed: nil,
                handoffLineHex: handoffLineHex,
                linkLine: linkLine,
                linkHex: linkHex,
                handoffSubtextHex: handoffSubtextHex
            )
        }
    case .enrolling:
        return WatchHomeHero(
            title: title,
            titleHex: WatchHomePalette.cream,
            titleIsLarge: true,
            titleLineLimit: 1,
            elapsedDisplay: nil,
            elapsedHex: elapsedHex,
            spokenElapsed: nil,
            handoffLineHex: handoffLineHex,
            linkLine: linkLine,
            linkHex: linkHex,
            handoffSubtextHex: handoffSubtextHex
        )
    case .off:
        return WatchHomeHero(
            title: title,
            titleHex: WatchHomePalette.calm,
            titleIsLarge: true,
            titleLineLimit: 1,
            elapsedDisplay: nil,
            elapsedHex: elapsedHex,
            spokenElapsed: nil,
            handoffLineHex: handoffLineHex,
            linkLine: linkLine,
            linkHex: linkHex,
            handoffSubtextHex: handoffSubtextHex
        )
    case .needsAttention:
        return WatchHomeHero(
            title: title,
            titleHex: WatchHomePalette.alert,
            titleIsLarge: true,
            titleLineLimit: 2,
            elapsedDisplay: nil,
            elapsedHex: elapsedHex,
            spokenElapsed: nil,
            handoffLineHex: handoffLineHex,
            linkLine: linkLine,
            linkHex: linkHex,
            handoffSubtextHex: handoffSubtextHex
        )
    }
}
