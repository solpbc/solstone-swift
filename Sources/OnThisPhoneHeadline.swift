// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OnThisPhoneHeadline: Equatable {
    enum Role: Equatable {
        case syncing
        case upToDate
        case needsAttention
    }

    struct Line: Equatable {
        let text: String
        let role: Role
    }

    let lines: [Line]
}

nonisolated func onThisPhoneHeadline(
    migration: OnThisPhoneMigration,
    reachingJournal: Bool? = nil
) -> OnThisPhoneHeadline {
    guard !migration.isEmpty else { return OnThisPhoneHeadline(lines: []) }
    let backlog = migration.onThisPhone + migration.onItsWay
    var lines: [OnThisPhoneHeadline.Line] = []

    if migration.needsAttention > 0 {
        lines.append(.init(
            text: SourceVocabulary.migrationStageCount(
                migration.needsAttention,
                stage: SourceVocabulary.needsAttention
            ),
            role: .needsAttention
        ))
    }

    if backlog > 0 {
        // L3: when reachingJournal == false, swap the syncing line to stuck copy.
        lines.append(.init(
            text: SourceVocabulary.migrationHeadlineSyncing(count: backlog),
            role: .syncing
        ))
    } else if migration.needsAttention == 0 {
        lines.append(.init(
            text: SourceVocabulary.migrationHeadlineUpToDate,
            role: .upToDate
        ))
    }

    return OnThisPhoneHeadline(lines: lines)
}

nonisolated func onThisPhoneLastActive(items: [OnThisPhoneItem]) -> Date? {
    items.compactMap { $0.lastAttemptAt ?? $0.deliveredAt }.max()
}
