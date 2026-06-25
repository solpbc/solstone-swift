// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

extension SourceVocabulary {
    nonisolated static let finishSyncingCardHeadline = "still syncing to your journal"

    nonisolated static func finishSyncingCardBody(count: Int) -> String {
        count == 1
            ? "1 observation hasn't landed yet. tap to keep syncing for a bit after you switch away from solstone."
            : "\(count) observations haven't landed yet. tap to keep syncing for a bit after you switch away from solstone."
    }

    nonisolated static let finishSyncingButton = "finish syncing now"
    nonisolated static let finishSyncingInProgress = "finishing up in the background. you can switch away — solstone keeps syncing for as long as iOS allows."
    nonisolated static let finishSyncingCompleted = "done — everything's in your journal now."

    nonisolated static func finishSyncingInterrupted(count: Int) -> String {
        count == 1
            ? "stopped — 1 still waiting. it's safe on this phone and will keep syncing whenever solstone is open."
            : "stopped — \(count) still waiting. they're safe on this phone and will keep syncing whenever solstone is open."
    }

    nonisolated static let finishSyncingInterruptedFallback = "stopped before everything synced. what's left is safe on this phone and keeps trying whenever solstone is open."
    nonisolated static let finishSyncingUnavailableRegistration = "finish syncing isn't available on this phone."
    nonisolated static let finishSyncingUnavailableUnavailable = "background syncing isn't available right now."
    nonisolated static let finishSyncingUnavailableNotPermitted = "iOS isn't allowing finish syncing right now."
    nonisolated static let finishSyncingUnavailableTooManyPending = "iOS already has too many background tasks waiting."
    nonisolated static let finishSyncingUnavailableImmediateIneligible = "iOS can't start finish syncing right now."
    nonisolated static let finishSyncingUnavailableFallback = "finish syncing couldn't start."
    nonisolated static let finishSyncingSystemTitle = "finishing sync"
    nonisolated static let finishSyncingSystemDoneTitle = "sync finished"
    nonisolated static let finishSyncingSystemPausedTitle = "sync paused"

    nonisolated static func finishSyncingSystemSubtitle(remaining: Int) -> String {
        remaining == 1 ? "1 item still waiting for your journal" : "\(remaining) items still waiting for your journal"
    }

    nonisolated static func standingSyncFootnote(sustaining: Bool) -> String {
        sustaining
            ? "syncs while solstone is open, and keeps going in the background while location is on."
            : "solstone syncs to your journal while it's open, and keeps going in the background for as long as your phone allows — longer when you have location on."
    }
}
