// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class FoldersSourceHandle {
    let source: FoldersEngine

    init(source: FoldersEngine) {
        self.source = source
    }
}

@MainActor
func makeFoldersSource(_ source: FoldersEngine) -> Source {
    let rollup = source.tileRollup()
    return Source(
        id: "folders",
        displayName: FoldersVocabulary.label,
        kind: .folders,
        state: rollup.state,
        isJournalPaired: source.isPaired,
        activeSubtext: rollup.subtext ?? FoldersVocabulary.label,
        subtextOverride: rollup.subtext,
        attention: rollup.state == .needsAttention ? rollup.subtext.map { SourceAttention(message: $0) } : nil,
        pendingStatus: .nonePending,
        showsSubtext: rollup.showsSubtext
    )
}

/// The `folders` Home tile manages zero-to-many folders with independent states,
/// so the tile itself carries no master toggle switch; tapping opens the folder list.
nonisolated func foldersTileControl() -> HomeSourceTileControl {
    .none
}
