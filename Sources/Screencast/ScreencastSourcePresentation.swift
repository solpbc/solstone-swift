// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func screencastSourcePresentation(
    managerState: ScreencastManager.State,
    isJournalPaired: Bool
) -> Source {
    let state = screencastSourceState(for: managerState)
    let subtextOverride: String
    let attention: SourceAttention?

    switch managerState {
    case .off:
        subtextOverride = SourceVocabulary.screencastOffSubtext
        attention = nil
    case .starting:
        subtextOverride = SourceVocabulary.screencastStartingSubtext
        attention = nil
    case .active:
        subtextOverride = SourceVocabulary.screencastActiveSubtext
        attention = nil
    case .needsAttention(let reason):
        subtextOverride = SourceVocabulary.screencastAttentionSubtext
        attention = SourceAttention(message: screencastAttentionMessage(reason))
    case .unavailable:
        subtextOverride = SourceVocabulary.screencastUnavailableSubtext
        attention = SourceAttention(message: SourceVocabulary.screencastUnavailableText)
    }

    return Source(
        id: "screencast",
        displayName: SourceVocabulary.screencastDisplayName,
        kind: .screencast,
        state: state,
        isJournalPaired: isJournalPaired,
        activeSubtext: SourceVocabulary.screencastActiveSubtext,
        subtextOverride: subtextOverride,
        attention: attention,
        pendingStatus: .nonePending
    )
}

nonisolated func screencastAttentionMessage(_ attention: ScreencastAttention) -> String {
    switch attention {
    case .noVideo:
        SourceVocabulary.screencastNoVideoText
    case .finalizeFailed:
        SourceVocabulary.screencastFinalizeFailedText
    case .staleOrMissingPointer:
        SourceVocabulary.screencastPointerFailedText
    case .appGroupUnavailable:
        SourceVocabulary.screencastUnavailableText
    }
}
