// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated enum SourceKind: Codable, Equatable, Hashable, Sendable {
    case observer
    case location
    case screencast
    case watch
}

nonisolated struct SourceAttention: Equatable, Sendable {
    let message: String

    init(message: String) {
        self.message = message
    }
}

nonisolated enum SourcePendingStatus: Equatable, Sendable {
    case nonePending
}

nonisolated struct Source: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let kind: SourceKind
    let state: SourceState
    let isJournalPaired: Bool
    let activeSubtext: String
    let subtextOverride: String?
    let attention: SourceAttention?
    let pendingStatus: SourcePendingStatus
    let showsSubtext: Bool

    init(
        id: String,
        displayName: String,
        kind: SourceKind,
        state: SourceState,
        isJournalPaired: Bool,
        activeSubtext: String,
        subtextOverride: String? = nil,
        attention: SourceAttention?,
        pendingStatus: SourcePendingStatus,
        showsSubtext: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.state = state
        self.isJournalPaired = isJournalPaired
        self.activeSubtext = activeSubtext
        self.subtextOverride = subtextOverride
        self.attention = attention
        self.pendingStatus = pendingStatus
        self.showsSubtext = showsSubtext
    }

    var subtext: String? {
        self.subtextOverride ?? self.state.subtext(
            activeSubtext: self.activeSubtext,
            isJournalPaired: self.isJournalPaired
        )
    }

    /// The sub-line a list row shows under the state word, when there is one.
    ///
    /// Suppressed when it would only restate the state word: `screen` supplies `off`
    /// as its own override, which rendered as "off / off". A sub-line that repeats
    /// the line above it is noise, not information. Also absent for `readyToSetUp`,
    /// where the state word is the whole message.
    var rowSubtext: String? {
        guard self.showsSubtext, let subtext = self.subtext, subtext != self.state.label else { return nil }
        return subtext
    }

    var voiceOverText: String {
        guard self.showsSubtext else {
            return self.state.label
        }
        let base: String
        if let subtextOverride {
            base = "\(self.state.label). \(Self.sentence(subtextOverride))"
        } else {
            base = self.state.voiceOverText(
                activeSubtext: self.activeSubtext,
                isJournalPaired: self.isJournalPaired
            )
        }
        return base
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
