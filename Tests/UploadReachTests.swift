// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class UploadReachTests: XCTestCase {
    func testUploadReachReachingWhenAnyBacklogElseIdle() {
        XCTAssertEqual(uploadReach(failedTotal: 264, pendingTotal: 98), .reaching)
        XCTAssertEqual(uploadReach(failedTotal: 5, pendingTotal: 0), .reaching)
        XCTAssertEqual(uploadReach(failedTotal: 0, pendingTotal: 3), .reaching)
        XCTAssertEqual(uploadReach(failedTotal: 0, pendingTotal: 0), .idle)
    }

    func testStandingSegmentReachDerivesBacklogExcludingDeliveredItems() {
        XCTAssertEqual(
            standingSegmentReach(migration: OnThisPhoneMigration(onThisPhone: 0, needsAttention: 1)),
            .reaching
        )
        XCTAssertEqual(
            standingSegmentReach(migration: OnThisPhoneMigration(onThisPhone: 2, needsAttention: 0)),
            .reaching
        )
        XCTAssertEqual(
            standingSegmentReach(migration: OnThisPhoneMigration(onThisPhone: 0, needsAttention: 0)),
            .idle
        )
    }

    @MainActor
    func testStandingHealthCombinesConnectionAndUploadReach() {
        XCTAssertEqual(
            SourceVocabulary.standingHealth(isConnected: false, reach: .idle).health,
            .unknown
        )
        XCTAssertFalse(SourceVocabulary.standingHealth(isConnected: false, reach: .idle).syncing)

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
            Self.standingLine(isConnected: true, reach: .reaching),
            "connected · syncing"
        )
        XCTAssertEqual(
            Self.standingLine(isConnected: true, reach: .idle),
            "connected"
        )
    }

    @MainActor
    private static func standingLine(isConnected: Bool, reach: UploadReach) -> String {
        let standing = SourceVocabulary.standingHealth(isConnected: isConnected, reach: reach)
        return SourceVocabulary.standingSyncLine(health: standing.health, syncing: standing.syncing)
    }
}
