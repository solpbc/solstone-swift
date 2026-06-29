// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func screencastSourcePresentation(
    managerState: ScreencastManager.State,
    summary: MobileSegmentSourceSummary
) -> Source {
    let baseState = screencastSourceState(for: managerState)
    let state = summary.failedCount > 0 ? SourceState.needsAttention : baseState
    let subtextOverride: String
    let attention: SourceAttention?

    switch managerState {
    case .off:
        subtextOverride = SourceVocabulary.screencastOffSubtext
        attention = summary.failedCount > 0 ? SourceAttention(message: SourceVocabulary.needsAttentionSubtext) : nil
    case .starting:
        subtextOverride = SourceVocabulary.screencastStartingSubtext
        attention = summary.failedCount > 0 ? SourceAttention(message: SourceVocabulary.needsAttentionSubtext) : nil
    case .active:
        subtextOverride = SourceVocabulary.screencastActiveSubtext
        attention = summary.failedCount > 0 ? SourceAttention(message: SourceVocabulary.needsAttentionSubtext) : nil
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
        group: .experiencingAlongsideYou,
        state: state,
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
