// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ObserverStatusPresentation: Equatable, Sendable {
    case unavailable
    case notPaired
    case needsAttention
    case waiting(count: Int)
    case awaitingMarkConfirmation(count: Int)
    case audioInterrupted
    case caughtUp

    var label: String {
        switch self {
        case .unavailable:
            SourceVocabulary.screencastUnavailableSubtext
        case .notPaired:
            SourceVocabulary.notPaired
        case .needsAttention:
            SourceVocabulary.needsAttention
        case .waiting:
            SourceVocabulary.waitingToSync
        case .awaitingMarkConfirmation:
            SourceVocabulary.confirmTheMarkAction
        case .audioInterrupted:
            SourceVocabulary.audioInterruptedHeadline
        case .caughtUp:
            SourceVocabulary.syncedHeadline
        }
    }

    var symbol: String {
        switch self {
        case .unavailable:
            "questionmark.circle"
        case .notPaired:
            "questionmark.circle"
        case .needsAttention:
            "exclamationmark.triangle"
        case .waiting:
            "arrow.triangle.2.circlepath"
        case .awaitingMarkConfirmation:
            "hand.raised"
        case .audioInterrupted:
            "waveform.badge.exclamationmark"
        case .caughtUp:
            "checkmark.circle"
        }
    }

    var count: Int? {
        switch self {
        case let .waiting(count):
            count
        case let .awaitingMarkConfirmation(count):
            count > 0 ? count : nil
        case .unavailable, .notPaired, .needsAttention, .audioInterrupted, .caughtUp:
            nil
        }
    }
}

nonisolated enum ObserverStatusPresentations {
    static func small(snapshot: AppGroupMirror.Snapshot?, sourceKind: SourceKind?) -> ObserverStatusPresentation {
        guard let snapshot,
              let sourceKind,
              snapshot.sourceStates[sourceKind] != nil
        else {
            return .unavailable
        }

        guard sourceKind != .watch else {
            return .unavailable
        }

        guard snapshot.pairing.isPaired else {
            return .notPaired
        }

        if snapshot.sourceStates[sourceKind] == .needsAttention {
            return .needsAttention
        }

        if snapshot.awaitingMarkConfirmation {
            return .awaitingMarkConfirmation(count: snapshot.backlogCount)
        }

        if snapshot.backlogCount > 0 {
            return .waiting(count: snapshot.backlogCount)
        }

        if snapshot.audioInterrupted {
            return .audioInterrupted
        }

        return .caughtUp
    }

    static func medium(snapshot: AppGroupMirror.Snapshot?) -> ObserverStatusPresentation {
        guard let snapshot else {
            return .unavailable
        }

        guard snapshot.pairing.isPaired else {
            return .notPaired
        }

        if snapshot.sourceStates.values.contains(.needsAttention) {
            return .needsAttention
        }

        if snapshot.awaitingMarkConfirmation {
            return .awaitingMarkConfirmation(count: snapshot.backlogCount)
        }

        if snapshot.backlogCount > 0 {
            return .waiting(count: snapshot.backlogCount)
        }

        if snapshot.audioInterrupted {
            return .audioInterrupted
        }

        return .caughtUp
    }

    static func circular(snapshot: AppGroupMirror.Snapshot?) -> ObserverStatusPresentation {
        guard let snapshot else {
            return .unavailable
        }

        guard snapshot.pairing.isPaired else {
            return .notPaired
        }

        if snapshot.awaitingMarkConfirmation {
            return .awaitingMarkConfirmation(count: snapshot.backlogCount)
        }

        if snapshot.backlogCount > 0 {
            return .waiting(count: snapshot.backlogCount)
        }

        if snapshot.audioInterrupted {
            return .audioInterrupted
        }

        return .caughtUp
    }
}
