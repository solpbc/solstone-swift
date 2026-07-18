// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated enum SourceKind: Equatable, Sendable {
    case observer
    case importer
    case location
    case omi
    case screencast
    case watch
}

nonisolated enum SourceGroup: Equatable, Sendable {
    case experiencingAlongsideYou
    case bringingInYourself

    var header: String {
        switch self {
        case .experiencingAlongsideYou:
            SourceVocabulary.experiencingAlongsideYouHeader
        case .bringingInYourself:
            SourceVocabulary.bringingInYourselfHeader
        }
    }
}

nonisolated struct SourceAttention: Equatable, Sendable {
    let message: String
    let actionHint: String?

    init(message: String, actionHint: String? = nil) {
        self.message = message
        self.actionHint = actionHint
    }
}

nonisolated enum SourcePendingStatus: Equatable, Sendable {
    case nonePending
}

nonisolated struct Source: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let kind: SourceKind
    let group: SourceGroup
    let state: SourceState
    let isJournalPaired: Bool
    let activeSubtext: String
    let subtextOverride: String?
    let attention: SourceAttention?
    let pendingStatus: SourcePendingStatus
    let detailSubtext: String?

    init(
        id: String,
        displayName: String,
        kind: SourceKind,
        group: SourceGroup,
        state: SourceState,
        isJournalPaired: Bool,
        activeSubtext: String,
        subtextOverride: String? = nil,
        attention: SourceAttention?,
        pendingStatus: SourcePendingStatus,
        detailSubtext: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.group = group
        self.state = state
        self.isJournalPaired = isJournalPaired
        self.activeSubtext = activeSubtext
        self.subtextOverride = subtextOverride
        self.attention = attention
        self.pendingStatus = pendingStatus
        self.detailSubtext = detailSubtext
    }

    var subtext: String {
        self.subtextOverride ?? self.state.subtext(
            activeSubtext: self.activeSubtext,
            isJournalPaired: self.isJournalPaired
        )
    }

    var voiceOverText: String {
        let base: String
        if let subtextOverride {
            base = "\(self.state.label). \(Self.sentence(subtextOverride))"
        } else {
            base = self.state.voiceOverText(
                activeSubtext: self.activeSubtext,
                isJournalPaired: self.isJournalPaired
            )
        }
        guard let detailSubtext else {
            return base
        }
        return "\(base) \(detailSubtext)."
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : "\(text)."
    }
}

@MainActor
@Observable
final class ObserverSourcePauseState {
    var isPaused = false
}
