// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OnThisPhoneHeadlineTests: XCTestCase {
    func testNeedsAttentionOnlyProducesNeedsAttentionLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(needsAttention: 1), isPaired: false)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "1 needs attention", role: .needsAttention),
        ])
    }

    func testPairedNeedsAttentionMergesWithBacklogIntoTroubleLine() {
        let headline = onThisPhoneHeadline(
            migration: Self.migration(onItsWay: 2, needsAttention: 1),
            isPaired: true
        )

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "3 waiting · trouble reaching your journal", role: .trouble),
        ])
    }

    func testOnThisPhoneBacklogProducesSingularSyncingLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(onThisPhone: 1), isPaired: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "syncing 1 segment to your journal", role: .syncing),
        ])
    }

    func testOnItsWayBacklogProducesPluralSyncingLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(onItsWay: 2), isPaired: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "syncing 2 segments to your journal", role: .syncing),
        ])
    }

    func testPairedNeedsAttentionOnlyProducesTroubleLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(needsAttention: 1), isPaired: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "1 waiting · trouble reaching your journal", role: .trouble),
        ])
    }

    func testDeliveredOnlyProducesUpToDateLine() {
        let headline = onThisPhoneHeadline(migration: Self.migration(inYourJournal: 3), isPaired: true)

        XCTAssertEqual(headline.lines, [
            OnThisPhoneHeadline.Line(text: "your journal is up to date", role: .upToDate),
        ])
    }

    func testEmptyMigrationProducesNoLines() {
        let headline = onThisPhoneHeadline(migration: Self.migration(), isPaired: true)

        XCTAssertEqual(headline.lines, [])
    }

    func testUnpairedOnItsWayWithoutNeedsAttentionProducesNoLines() {
        let headline = onThisPhoneHeadline(migration: Self.migration(onItsWay: 2), isPaired: false)

        XCTAssertEqual(headline.lines, [])
    }

    func testUnpairedEmptyMigrationProducesNoLines() {
        let headline = onThisPhoneHeadline(migration: Self.migration(), isPaired: false)

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
