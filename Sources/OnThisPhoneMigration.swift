// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OnThisPhoneMigration: Equatable, Sendable {
    let onThisPhone: Int // savedOnThisPhone + sending — the honest backlog
    let needsAttention: Int // stays 0 in prod; feeds L4
    let failedRepresented: Int // items with retryAvailable == true — reconciliation input

    init(
        onThisPhone: Int,
        needsAttention: Int,
        failedRepresented: Int = 0
    ) {
        self.onThisPhone = onThisPhone
        self.needsAttention = needsAttention
        self.failedRepresented = failedRepresented
    }

    var backlog: Int { self.onThisPhone }
    var total: Int { self.onThisPhone + self.needsAttention }
    var isEmpty: Bool { self.total == 0 }
}

/// What finish-syncing offers to send: everything waiting, less the refusals the engine is pacing,
/// which a finish-syncing run would not send.
nonisolated func finishSyncingBacklogCount(snapshot: OnThisPhoneAggregateSnapshot) -> Int {
    let migration = onThisPhoneMigration(snapshot: snapshot)
    let paced = snapshot.items.filter { $0.sendState == .needsAttention && $0.refusalPaced }.count
    return migration.onThisPhone + migration.needsAttention - paced
}

nonisolated func onThisPhoneMigration(
    snapshot: OnThisPhoneAggregateSnapshot
) -> OnThisPhoneMigration {
    var onThisPhone = 0
    var needsAttention = 0
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
        case .sending:
            onThisPhone += 1
        }
    }

    return OnThisPhoneMigration(
        onThisPhone: onThisPhone,
        needsAttention: needsAttention,
        failedRepresented: failedRepresented
    )
}
