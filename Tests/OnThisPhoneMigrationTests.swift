// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneMigrationTests: XCTestCase {
    @MainActor
    func testFrozenCountGuardDifferentiatesPendingAndDeliveredSnapshots() {
        let pending = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.savedOnThisPhone, .savedOnThisPhone, .savedOnThisPhone])
        )
        let delivered = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.inYourJournal, .inYourJournal, .inYourJournal])
        )

        XCTAssertEqual(pending.onThisPhone, 3)
        XCTAssertEqual(pending.onItsWay, 0)
        XCTAssertEqual(pending.inYourJournal, 0)
        XCTAssertEqual(delivered.onItsWay, 0)
        XCTAssertEqual(delivered.inYourJournal, 3)
        XCTAssertNotEqual(pending, delivered)
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
            ])
        )

        XCTAssertEqual(migration.needsAttention, 2)
        XCTAssertEqual(migration.onThisPhone, 1)
        XCTAssertEqual(migration.onItsWay, 1)
        XCTAssertEqual(migration.inYourJournal, 2)
    }

    @MainActor
    func testEmptyStalledAndColdLaunchEdgesStayHonest() {
        let empty = onThisPhoneMigration(snapshot: Self.snapshot(states: []))
        let stalled = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.savedOnThisPhone, .savedOnThisPhone, .inYourJournal])
        )
        let delivered = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.inYourJournal])
        )

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(stalled.onThisPhone, 2)
        XCTAssertEqual(stalled.onItsWay, 0)
        XCTAssertEqual(stalled.inYourJournal, 1)
        XCTAssertEqual(delivered.inYourJournal, 1)
    }

    @MainActor
    func testNeedsAttentionOnlyDoesNotFabricateLifecycleBuckets() {
        let migration = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.needsAttention, .needsAttention])
        )

        XCTAssertEqual(migration.onThisPhone, 0)
        XCTAssertEqual(migration.onItsWay, 0)
        XCTAssertEqual(migration.inYourJournal, 0)
        XCTAssertEqual(migration.needsAttention, 2)
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
