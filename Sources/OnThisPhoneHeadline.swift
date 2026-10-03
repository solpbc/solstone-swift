// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OnThisPhoneHeadline: Equatable, Sendable {
    let onThisPhone: Int
    let needsAttention: Int
    let role: Role

    enum Role: Equatable, Sendable {
        case syncing
        case upToDate
        /// Nothing waiting, but some owner audio never reached the journal.
        case audioInterrupted
        case offline
        case needsAttentionOnly
        case none
        case awaitingMarkConfirmation
    }
}

nonisolated func onThisPhoneHeadline(
    migration: OnThisPhoneMigration,
    isPaired: Bool,
    isConnected: Bool,
    awaitingMarkConfirmation: Bool,
    isStalled: Bool,
    connectionStatus: ConnectionSyncStatus,
    hasAudioInterruption: Bool = false
) -> OnThisPhoneHeadline {
    let role: OnThisPhoneHeadline.Role

    if !isPaired {
        role = migration.needsAttention > 0 ? .needsAttentionOnly : .none
    } else if migration.onThisPhone > 0 {
        if MarkConfirmationDisplay.showsAwaitingWords(
            awaitingMarkConfirmation: awaitingMarkConfirmation,
            status: connectionStatus,
            isStalled: isStalled
        ) {
            role = .awaitingMarkConfirmation
        } else {
            role = isConnected ? .syncing : .offline
        }
    } else if migration.needsAttention == 0 {
        role = hasAudioInterruption ? .audioInterrupted : .upToDate
    } else {
        role = .needsAttentionOnly
    }

    return OnThisPhoneHeadline(
        onThisPhone: migration.onThisPhone,
        needsAttention: migration.needsAttention,
        role: role
    )
}
