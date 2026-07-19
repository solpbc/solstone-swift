// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OnThisPhoneScopeLineTests: XCTestCase {
    @MainActor
    func testOfflineWithEmptyBacklogSuppressesScopeLine() {
        let migration = OnThisPhoneMigration(onThisPhone: 0, needsAttention: 0)

        XCTAssertNil(onThisPhoneScopeLine(state: .linkedOffline, migration: migration))
    }

    @MainActor
    func testOfflineWithPendingBacklogShowsOfflineScopeLine() {
        let migration = OnThisPhoneMigration(onThisPhone: 1, needsAttention: 0)

        XCTAssertEqual(
            onThisPhoneScopeLine(state: .linkedOffline, migration: migration),
            SourceVocabulary.onThisPhoneScopeOfflinePaired
        )
    }

    @MainActor
    func testOfflineWithNeedsAttentionBacklogShowsOfflineScopeLine() {
        let migration = OnThisPhoneMigration(onThisPhone: 0, needsAttention: 1)

        XCTAssertEqual(
            onThisPhoneScopeLine(state: .linkedOffline, migration: migration),
            SourceVocabulary.onThisPhoneScopeOfflinePaired
        )
    }

    @MainActor
    func testOnlineShowsConnectedScopeLine() {
        let migration = OnThisPhoneMigration(onThisPhone: 0, needsAttention: 0)

        XCTAssertEqual(
            onThisPhoneScopeLine(state: .linkedOnline, migration: migration),
            SourceVocabulary.onThisPhoneScopeConnected
        )
    }

    @MainActor
    func testNoJournalAndNilShowDefaultScopeLine() {
        let migration = OnThisPhoneMigration(onThisPhone: 0, needsAttention: 0)

        XCTAssertEqual(
            onThisPhoneScopeLine(state: .noJournal, migration: migration),
            SourceVocabulary.onThisPhoneScope
        )
        XCTAssertEqual(
            onThisPhoneScopeLine(state: nil, migration: migration),
            SourceVocabulary.onThisPhoneScope
        )
    }
}
