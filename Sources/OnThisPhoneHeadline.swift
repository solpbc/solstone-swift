// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OnThisPhoneHeadline: Equatable {
    enum Role: Equatable {
        case syncing
        case trouble
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
    isPaired: Bool
) -> OnThisPhoneHeadline {
    guard !migration.isEmpty else { return OnThisPhoneHeadline(lines: []) }

    if isPaired {
        let segmentBacklog = migration.onThisPhone + migration.onItsWay + migration.needsAttention
        guard segmentBacklog > 0 else {
            return OnThisPhoneHeadline(lines: [
                .init(text: SourceVocabulary.migrationHeadlineUpToDate, role: .upToDate),
            ])
        }
        let reaching = migration.needsAttention == 0
        return OnThisPhoneHeadline(lines: [
            .init(
                text: reaching
                    ? SourceVocabulary.migrationHeadlineSyncing(count: segmentBacklog)
                    : SourceVocabulary.migrationHeadlineTrouble(count: segmentBacklog),
                role: reaching ? .syncing : .trouble
            ),
        ])
    }

    // unpaired: surface only the local needs-attention line (consumed where pairing is absent)
    guard migration.needsAttention > 0 else { return OnThisPhoneHeadline(lines: []) }
    return OnThisPhoneHeadline(lines: [
        .init(
            text: SourceVocabulary.migrationStageCount(
                migration.needsAttention,
                stage: SourceVocabulary.needsAttention
            ),
            role: .needsAttention
        ),
    ])
}

nonisolated func onThisPhoneLastActive(items: [OnThisPhoneItem]) -> Date? {
    items.compactMap { $0.lastAttemptAt ?? $0.deliveredAt }.max()
}
