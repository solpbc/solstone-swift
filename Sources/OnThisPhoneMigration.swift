// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OnThisPhoneMigration: Equatable, Sendable {
    let onThisPhone: Int
    let needsAttention: Int

    var total: Int { self.onThisPhone + self.needsAttention }
    var isEmpty: Bool { self.total == 0 }
}

nonisolated func onThisPhoneMigration(
    snapshot: OnThisPhoneAggregateSnapshot
) -> OnThisPhoneMigration {
    var onThisPhone = 0
    var needsAttention = 0

    for item in snapshot.items {
        switch item.sendState {
        case .inYourJournal:
            break
        case .needsAttention:
            needsAttention += 1
        case .savedOnThisPhone, .sending:
            onThisPhone += 1
        }
    }

    return OnThisPhoneMigration(
        onThisPhone: onThisPhone,
        needsAttention: needsAttention
    )
}
