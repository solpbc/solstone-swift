// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated enum SourceKind: Equatable, Sendable {
    case observer
    case importer
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
    let activeSubtext: String
    let attention: SourceAttention?
    let pendingStatus: SourcePendingStatus
    let isJournalConnected: Bool

    var subtext: String {
        self.state.subtext(activeSubtext: self.activeSubtext)
    }

    var voiceOverText: String {
        self.state.voiceOverText(activeSubtext: self.activeSubtext)
    }
}

@MainActor
@Observable
final class ObserverSourcePauseState {
    var isPaused = false
}
