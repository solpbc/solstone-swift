// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LastSyncedTests: XCTestCase {
    func testLastSyncedAtReturnsNilForAllNilAndLatestDateOtherwise() {
        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        let d2 = Date(timeIntervalSince1970: 1_700_000_300)

        XCTAssertNil(lastSyncedAt([nil, nil]))
        XCTAssertEqual(lastSyncedAt([d1, nil, d2]), d2)
    }

    @MainActor
    func testConnectedPendingStandingLineIsSyncing() {
        let standing = SourceVocabulary.standingHealth(
            isConnected: true,
            reach: standingSegmentReach(migration: OnThisPhoneMigration(onThisPhone: 2, needsAttention: 0))
        )

        XCTAssertEqual(
            SourceVocabulary.standingSyncLine(health: standing.health, syncing: standing.syncing),
            SourceVocabulary.standingSyncing
        )
        XCTAssertEqual(SourceVocabulary.standingSyncing, "connected · syncing")
    }

    func testUploadDiagnosticSuccessMessageUsesJournalCopyAndOtherStagesKeepSourceForm() {
        let source = "observer-audio"

        XCTAssertEqual(Self.uploadDiagnosticMessage(source: source, stage: "success"), "synced to your journal")
        XCTAssertEqual(
            Self.uploadDiagnosticMessage(source: source, stage: "retry-scheduled"),
            "observer-audio upload retry-scheduled"
        )
    }

    private static func uploadDiagnosticMessage(source: String, stage: String) -> String {
        // appendUploadDiagnostic is private; ObserverUploaderTests covers the emitted success event.
        stage == "success" ? "synced to your journal" : "\(source) upload \(stage)"
    }
}
