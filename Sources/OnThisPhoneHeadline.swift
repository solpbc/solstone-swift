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
        case offline
        case needsAttentionOnly
        case none
    }
}

nonisolated func onThisPhoneHeadline(
    migration: OnThisPhoneMigration,
    isPaired: Bool,
    isConnected: Bool
) -> OnThisPhoneHeadline {
    let role: OnThisPhoneHeadline.Role

    if !isPaired {
        role = migration.needsAttention > 0 ? .needsAttentionOnly : .none
    } else if migration.onThisPhone > 0 {
        role = isConnected ? .syncing : .offline
    } else if migration.needsAttention == 0 {
        role = .upToDate
    } else {
        role = .needsAttentionOnly
    }

    return OnThisPhoneHeadline(
        onThisPhone: migration.onThisPhone,
        needsAttention: migration.needsAttention,
        role: role
    )
}
