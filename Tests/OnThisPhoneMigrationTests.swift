// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneMigrationTests: XCTestCase {
    @MainActor
    func testFrozenCountGuardDifferentiatesPendingAndDeliveredSnapshots() {
        let pending = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.savedOnThisPhone, .savedOnThisPhone, .savedOnThisPhone]),
            journalConnected: true
        )
        let delivered = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.inYourJournal, .inYourJournal, .inYourJournal]),
            journalConnected: true
        )

        XCTAssertEqual(pending.onItsWay, 3)
        XCTAssertEqual(pending.inYourJournal, 0)
        XCTAssertEqual(delivered.onItsWay, 0)
        XCTAssertEqual(delivered.inYourJournal, 3)
        XCTAssertNotEqual(pending, delivered)
    }

    @MainActor
    func testCompletionRequiresAllDeliveredAfterUndeliveredWasSeen() {
        let undelivered = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.savedOnThisPhone]),
            journalConnected: true
        )
        let delivered = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.inYourJournal]),
            journalConnected: true
        )

        XCTAssertFalse(undelivered.showsCompletion(sawUndelivered: true))
        XCTAssertTrue(delivered.showsCompletion(sawUndelivered: true))
    }

    @MainActor
    func testMixedMigrationKeepsDeliveredPartialAndAttentionDistinct() {
        let migration = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [
                .sending,
                .savedOnThisPhone,
                .inYourJournal,
                .inYourJournal,
                .needsAttention,
                .needsAttention,
            ]),
            journalConnected: true
        )

        XCTAssertFalse(migration.isAllDelivered)
        XCTAssertEqual(migration.needsAttention, 2)
        XCTAssertEqual(migration.onItsWay, 2)
        XCTAssertEqual(migration.inYourJournal, 2)
        XCTAssertFalse(migration.showsCompletion(sawUndelivered: true))
        XCTAssertEqual(SourceVocabulary.migrationReached(count: 1), "1 observation just reached your journal.")
        XCTAssertEqual(SourceVocabulary.migrationReached(count: 245), "245 observations just reached your journal.")
    }

    @MainActor
    func testEmptyStalledAndColdLaunchEdgesStayHonest() {
        let empty = onThisPhoneMigration(snapshot: Self.snapshot(states: []), journalConnected: false)
        let stalled = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.savedOnThisPhone, .savedOnThisPhone, .inYourJournal]),
            journalConnected: false
        )
        let delivered = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.inYourJournal]),
            journalConnected: false
        )

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(stalled.onThisPhone, 2)
        XCTAssertEqual(stalled.onItsWay, 0)
        XCTAssertEqual(stalled.inYourJournal, 1)
        XCTAssertFalse(stalled.isAllDelivered)
        XCTAssertFalse(stalled.showsCompletion(sawUndelivered: true))
        XCTAssertFalse(delivered.showsCompletion(sawUndelivered: false))
    }

    @MainActor
    func testNeedsAttentionOnlyDoesNotFabricateLifecycleBuckets() {
        let migration = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.needsAttention, .needsAttention]),
            journalConnected: true
        )

        XCTAssertEqual(migration.onThisPhone, 0)
        XCTAssertEqual(migration.onItsWay, 0)
        XCTAssertEqual(migration.inYourJournal, 0)
        XCTAssertEqual(migration.needsAttention, 2)
        XCTAssertFalse(migration.isAllDelivered)
        XCTAssertFalse(migration.showsCompletion(sawUndelivered: true))
    }
}

private extension OnThisPhoneMigrationTests {
    static func snapshot(states: [OnThisPhoneSendState]) -> OnThisPhoneAggregateSnapshot {
        let items = states.enumerated().map { index, state in
            Self.item(id: "item-\(index)", sendState: state)
        }
        return OnThisPhoneAggregateSnapshot(
            sources: [
                OnThisPhoneSourceSnapshot(sourceKind: .share, result: .loaded(items: items)),
            ],
            items: items
        )
    }

    static func item(id: String, sendState: OnThisPhoneSendState) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: id,
            sourceKind: .share,
            sendState: sendState,
            contentType: nil,
            filename: nil,
            bytes: nil,
            originApp: nil,
            basis: nil,
            itemTime: nil,
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: nil
        )
    }
}
