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
    var subtextOverrideRepeatsStateLabel = false
    let attention: SourceAttention?

    switch managerState {
    case .off:
        if let systemEndedAt,
           now.timeIntervalSince(systemEndedAt) <= ScreencastManager.systemEndedVisibleWindowSeconds {
            subtextOverride = String(localized: SourceVocabulary.screencastSystemEndedSubtext)
        } else {
            // Screen always supplies its own sub-line, so it never reaches the shared
            // fall-through — which means a never-set-up source would read
            // `ready to set up` over `off`. It gets no sub-line instead.
            subtextOverride = enrolled ? String(localized: SourceVocabulary.screencastOffSubtext) : nil
            subtextOverrideRepeatsStateLabel = enrolled
        }
        attention = nil
    case .starting:
        subtextOverride = String(localized: SourceVocabulary.screencastStartingSubtext)
        attention = nil
    case .active:
        subtextOverride = String(localized: SourceVocabulary.screencastActiveSubtext)
        attention = nil
    case .needsAttention(let reason):
        subtextOverride = String(localized: SourceVocabulary.screencastAttentionSubtext)
        subtextOverrideRepeatsStateLabel = true
        attention = SourceAttention(message: screencastAttentionMessage(reason))
    case .unavailable:
        subtextOverride = String(localized: SourceVocabulary.screencastUnavailableSubtext)
        attention = SourceAttention(message: String(localized: SourceVocabulary.screencastUnavailableText))
    }

    return Source(
        id: "screencast",
        displayName: String(localized: SourceVocabulary.screencastDisplayName),
        kind: .screencast,
        state: state,
        isJournalPaired: isJournalPaired,
        activeSubtext: String(localized: SourceVocabulary.screencastActiveSubtext),
        subtextOverride: subtextOverride,
        subtextOverrideRepeatsStateLabel: subtextOverrideRepeatsStateLabel,
        attention: attention,
        pendingStatus: .nonePending
    )
}

nonisolated func screencastAttentionMessage(_ attention: ScreencastAttention) -> String {
    switch attention {
    case .storageLow:
        String(localized: SourceVocabulary.screencastStorageLowText)
    case .noVideo:
        String(localized: SourceVocabulary.screencastNoVideoText)
    case .finalizeFailed:
        String(localized: SourceVocabulary.screencastFinalizeFailedText)
    case .appGroupUnavailable:
        String(localized: SourceVocabulary.screencastUnavailableText)
    }
}

extension SourceVocabulary {
    static func screencastPrimerBody(state: ScreencastManager.State) -> String {
        switch state {
        case .active:
            String(localized: screencastPrimerBodyActive)
        default:
            String(localized: screencastPrimerBodyOff)
        }
    }

    static func screencastActionTitle(state: ScreencastManager.State) -> String {
        switch state {
        case .active:
            String(localized: screencastOpenSystemSheet)
        default:
            String(localized: screencastStartButton)
        }
    }
}
