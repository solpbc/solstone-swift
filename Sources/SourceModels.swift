// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated enum SourceKind: Equatable, Sendable {
    case observer
    case importer
    case location
    case omi
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
    let detailSubtext: String?

    init(
        id: String,
        displayName: String,
        kind: SourceKind,
        group: SourceGroup,
        state: SourceState,
        activeSubtext: String,
        attention: SourceAttention?,
        pendingStatus: SourcePendingStatus,
        detailSubtext: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.group = group
        self.state = state
        self.activeSubtext = activeSubtext
        self.attention = attention
        self.pendingStatus = pendingStatus
        self.detailSubtext = detailSubtext
    }

    var subtext: String {
        self.state.subtext(activeSubtext: self.activeSubtext)
    }

    var voiceOverText: String {
        let base = self.state.voiceOverText(activeSubtext: self.activeSubtext)
        guard let detailSubtext else {
            return base
        }
        return "\(base) \(detailSubtext)."
    }
}

@MainActor
@Observable
final class ObserverSourcePauseState {
    var isPaused = false
}

nonisolated func importerSourceState(failedCount: Int) -> SourceState {
    failedCount == 0 ? .active : .needsAttention
}

nonisolated func importerActiveSubtext(
    pendingCount: Int,
    lastDeliveredAt: Date?
) -> String {
    if pendingCount > 0 {
        return SourceVocabulary.shareSendingProgress
    }
    if lastDeliveredAt != nil {
        return SourceVocabulary.shareDeliveredProgress
    }
    return SourceVocabulary.importerActiveSubtext
}
