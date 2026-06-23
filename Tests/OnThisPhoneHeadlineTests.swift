// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OnThisPhoneHeadlineTests: XCTestCase {
    func testNeedsAttentionOnlyProducesNeedsAttentionLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(needsAttention: 1), reachingJournal: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "1 needs attention", role: .needsAttention),
        ])
    }

    func testNeedsAttentionPrecedesSyncingWhenBacklogExists() {
        let headline = onThisPhoneHeadline(
            migration: Self.migration(onItsWay: 2, needsAttention: 1),
            reachingJournal: true
        )

        XCTAssertEqual(headline.lines.map(\.role), [.needsAttention, .syncing])
        XCTAssertEqual(headline.lines.map(\.text), [
            "1 needs attention",
            "syncing 2 items to your journal",
        ])
    }

    func testOnThisPhoneBacklogProducesSingularSyncingLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(onThisPhone: 1), reachingJournal: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "syncing 1 item to your journal", role: .syncing),
        ])
    }

    func testOnItsWayBacklogProducesPluralSyncingLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(onItsWay: 2), reachingJournal: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "syncing 2 items to your journal", role: .syncing),
        ])
    }

    func testDeliveredOnlyProducesUpToDateLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(inYourJournal: 3), reachingJournal: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "your journal is up to date", role: .upToDate),
        ])
    }

    func testEmptyMigrationProducesNoLines() {
        let headline = onThisPhoneHeadline(migration: Self.migration(), reachingJournal: true)

        XCTAssertEqual(headline.lines, [])
    }
}

private extension OnThisPhoneHeadlineTests {
    static func migration(
        onThisPhone: Int = 0,
        onItsWay: Int = 0,
        inYourJournal: Int = 0,
        needsAttention: Int = 0
    ) -> OnThisPhoneMigration {
        OnThisPhoneMigration(
            onThisPhone: onThisPhone,
            onItsWay: onItsWay,
            inYourJournal: inYourJournal,
            needsAttention: needsAttention
        )
    }
}
