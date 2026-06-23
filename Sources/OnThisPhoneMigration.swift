// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OnThisPhoneMigration: Equatable, Sendable {
    let onThisPhone: Int
    let onItsWay: Int
    let inYourJournal: Int
    let needsAttention: Int

    var total: Int { self.onThisPhone + self.onItsWay + self.inYourJournal + self.needsAttention }
    var isEmpty: Bool { self.total == 0 }
}

nonisolated func onThisPhoneMigration(
    snapshot: OnThisPhoneAggregateSnapshot
) -> OnThisPhoneMigration {
    var onThisPhone = 0
    var onItsWay = 0
    var inYourJournal = 0
    var needsAttention = 0

    for item in snapshot.items {
        switch item.sendState {
        case .inYourJournal:
            inYourJournal += 1
        case .needsAttention:
            needsAttention += 1
        case .savedOnThisPhone:
            onThisPhone += 1
        case .sending:
            onItsWay += 1
        }
    }

    return OnThisPhoneMigration(
        onThisPhone: onThisPhone,
        onItsWay: onItsWay,
        inYourJournal: inYourJournal,
        needsAttention: needsAttention
    )
}
