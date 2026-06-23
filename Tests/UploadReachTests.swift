// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class UploadReachTests: XCTestCase {
    func testUploadReachPrefersFailingThenReachingThenIdle() {
        XCTAssertEqual(uploadReach(failedTotal: 1, pendingTotal: 0), .failing)
        XCTAssertEqual(uploadReach(failedTotal: 1, pendingTotal: 3), .failing)
        XCTAssertEqual(uploadReach(failedTotal: 0, pendingTotal: 2), .reaching)
        XCTAssertEqual(uploadReach(failedTotal: 0, pendingTotal: 0), .idle)
    }

    @MainActor
    func testStandingHealthCombinesConnectionAndUploadReach() {
        XCTAssertEqual(
            SourceVocabulary.standingHealth(isConnected: false, reach: .failing).health,
            .unknown
        )
        XCTAssertFalse(SourceVocabulary.standingHealth(isConnected: false, reach: .failing).syncing)

        XCTAssertEqual(
            SourceVocabulary.standingHealth(isConnected: true, reach: .failing).health,
            .degraded
        )
        XCTAssertFalse(SourceVocabulary.standingHealth(isConnected: true, reach: .failing).syncing)

        XCTAssertEqual(
            SourceVocabulary.standingHealth(isConnected: true, reach: .reaching).health,
            .healthy
        )
        XCTAssertTrue(SourceVocabulary.standingHealth(isConnected: true, reach: .reaching).syncing)

        XCTAssertEqual(
            SourceVocabulary.standingHealth(isConnected: true, reach: .idle).health,
            .healthy
        )
        XCTAssertFalse(SourceVocabulary.standingHealth(isConnected: true, reach: .idle).syncing)
    }

    @MainActor
    func testStandingHealthFeedsLockedStandingCopy() {
        XCTAssertEqual(
            Self.standingLine(isConnected: false, reach: .idle),
            "offline"
        )
        XCTAssertEqual(
            Self.standingLine(isConnected: true, reach: .failing),
            "connected · trouble reaching your journal"
        )
        XCTAssertEqual(
            Self.standingLine(isConnected: true, reach: .reaching),
            "connected · syncing"
        )
        XCTAssertEqual(
            Self.standingLine(isConnected: true, reach: .idle),
            "connected"
        )
    }

    func testTroubleHeadlineUsesWaitingCopyWhenJournalIsNotReachable() {
        XCTAssertEqual(
            SourceVocabulary.migrationHeadlineTrouble(count: 1),
            "1 waiting · trouble reaching your journal"
        )
        XCTAssertEqual(
            SourceVocabulary.migrationHeadlineTrouble(count: 2),
            "2 waiting · trouble reaching your journal"
        )

        let headline = onThisPhoneHeadline(
            migration: OnThisPhoneMigration(
                onThisPhone: 1,
                onItsWay: 1,
                inYourJournal: 0,
                needsAttention: 0
            ),
            reachingJournal: false
        )

        XCTAssertEqual(headline.lines.count, 1)
        XCTAssertEqual(headline.lines.first?.role, .trouble)
        XCTAssertTrue(headline.lines.first?.text.contains("trouble reaching your journal") == true)
    }

    @MainActor
    private static func standingLine(isConnected: Bool, reach: UploadReach) -> String {
        let standing = SourceVocabulary.standingHealth(isConnected: isConnected, reach: reach)
        return SourceVocabulary.standingSyncLine(health: standing.health, syncing: standing.syncing)
    }
}
