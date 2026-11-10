// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Puts the Obsidian source in the SwiftUI environment.
@MainActor
@Observable
final class ObsidianSourceHandle {
    let source: any ObsidianEngineControlling

    init(source: any ObsidianEngineControlling) {
        self.source = source
    }
}

// MARK: - Source model for deck and status

@MainActor
func makeObsidianSource(_ source: any ObsidianEngineControlling, isJournalPaired: Bool) -> Source {
    let presentation = source.status
    return Source(
        id: "obsidian",
        displayName: ObsidianVocabulary.TITLE,
        kind: .obsidian,
        state: presentation.tileState,
        isJournalPaired: isJournalPaired,
        activeSubtext: ObsidianVocabulary.EXPLAINER,
        subtextOverride: nil,
        attention: presentation.attention.map { SourceAttention(message: $0.sentence) },
        pendingStatus: .nonePending
    )
}

nonisolated func obsidianTileControl(_ status: ObsidianSourceStatus) -> HomeSourceTileControl {
    switch status.tileState {
    case .active, .paused:
        .toggle
    case .off, .enrolling, .readyToSetUp, .checking, .needsAttention:
        .none
    }
}

@MainActor
func setObsidianTile(_ source: any ObsidianEngineControlling, on: Bool) async {
    if on {
        source.resume()
    } else {
        source.pause()
    }
}
