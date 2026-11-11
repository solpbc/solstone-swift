// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class ScreenshotsSourceHandle {
    let source: ScreenshotsSourceEngine

    init(source: ScreenshotsSourceEngine) {
        self.source = source
    }
}

@MainActor
func makeScreenshotsSource(_ source: ScreenshotsSourceEngine) -> Source {
    let snapshot = source.snapshot
    let view = snapshot.view
    return Source(
        id: "screenshots",
        displayName: ScreenshotsVocabulary.label,
        kind: .screenshots,
        state: view.sourceState,
        isJournalPaired: snapshot.paired,
        activeSubtext: view.activeSubtext,
        subtextOverride: view.subtextOverride,
        attention: view.pageReason.map { SourceAttention(message: $0) },
        pendingStatus: .nonePending,
        showsSubtext: view.showsSubtext
    )
}

nonisolated func screenshotsTileControl(_ view: ScreenshotsViewState) -> HomeSourceTileControl {
    switch view.sourceState {
    case .active, .paused:
        .toggle
    case .off, .enrolling, .readyToSetUp, .checking, .needsAttention:
        .none
    }
}

@MainActor
func setScreenshotsTile(_ source: ScreenshotsSourceEngine, on: Bool) async {
    if on {
        await source.resume()
    } else {
        source.pause()
    }
}
