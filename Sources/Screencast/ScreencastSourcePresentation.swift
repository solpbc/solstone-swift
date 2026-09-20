// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func screencastSourcePresentation(
    managerState: ScreencastManager.State,
    isJournalPaired: Bool,
    enrolled: Bool,
    systemEndedAt: Date? = nil,
    now: Date = Date()
) -> Source {
    let state = screencastSourceState(for: managerState, enrolled: enrolled)
    let subtextOverride: String?
    let attention: SourceAttention?

    switch managerState {
    case .off:
        if let systemEndedAt,
           now.timeIntervalSince(systemEndedAt) <= ScreencastManager.systemEndedVisibleWindowSeconds {
            subtextOverride = SourceVocabulary.screencastSystemEndedSubtext
        } else {
            // Screen always supplies its own sub-line, so it never reaches the shared
            // fall-through — which means a never-set-up source would read
            // `ready to set up` over `off`. It gets no sub-line instead.
            subtextOverride = enrolled ? SourceVocabulary.screencastOffSubtext : nil
        }
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
    case .storageLow:
        SourceVocabulary.screencastStorageLowText
    case .noVideo:
        SourceVocabulary.screencastNoVideoText
    case .finalizeFailed:
        SourceVocabulary.screencastFinalizeFailedText
    case .appGroupUnavailable:
        SourceVocabulary.screencastUnavailableText
    }
}

extension SourceVocabulary {
    static func screencastPrimerBody(state: ScreencastManager.State) -> String {
        switch state {
        case .active:
            screencastPrimerBodyActive
        default:
            screencastPrimerBodyOff
        }
    }

    static func screencastActionTitle(state: ScreencastManager.State) -> String {
        switch state {
        case .active:
            screencastOpenSystemSheet
        default:
            screencastStartButton
        }
    }
}
