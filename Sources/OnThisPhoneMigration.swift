// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OnThisPhoneMigration: Equatable, Sendable {
    let onThisPhone: Int // savedOnThisPhone + sending — the honest backlog
    let needsAttention: Int // stays 0 in prod; feeds L4
    let notReached: Int // savedOnThisPhone only (excludes .sending) — try-now target
    let failedRepresented: Int // items with retryAvailable == true — reconciliation input

    init(
        onThisPhone: Int,
        needsAttention: Int,
        notReached: Int = 0,
        failedRepresented: Int = 0
    ) {
        self.onThisPhone = onThisPhone
        self.needsAttention = needsAttention
        self.notReached = notReached
        self.failedRepresented = failedRepresented
    }

    var backlog: Int { self.onThisPhone }
    var total: Int { self.onThisPhone + self.needsAttention }
    var isEmpty: Bool { self.total == 0 }
}

nonisolated func onThisPhoneMigration(
    snapshot: OnThisPhoneAggregateSnapshot
) -> OnThisPhoneMigration {
    var onThisPhone = 0
    var needsAttention = 0
    var notReached = 0
    var failedRepresented = 0

    for item in snapshot.items {
        if item.retryAvailable {
            failedRepresented += 1
        }

        switch item.sendState {
        case .inYourJournal:
            break
        case .needsAttention:
            needsAttention += 1
        case .savedOnThisPhone:
            onThisPhone += 1
            notReached += 1
        case .sending:
            onThisPhone += 1
        }
    }

    return OnThisPhoneMigration(
        onThisPhone: onThisPhone,
        needsAttention: needsAttention,
        notReached: notReached,
        failedRepresented: failedRepresented
    )
}
