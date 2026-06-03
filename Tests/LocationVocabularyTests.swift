// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class LocationVocabularyTests: XCTestCase {
    func testLockedLocationCopyVerbatim() {
        XCTAssertEqual(LocationVocabulary.sourceDisplayName, "location")
        XCTAssertEqual(LocationVocabulary.activeSubtext, "adds where your day happens to your journal while this is on.")
        XCTAssertEqual(LocationVocabulary.preEnrollmentValue, "where your day happens — kept by you, in your journal, and nowhere else. as light or as complete as you want.")
        XCTAssertEqual(LocationVocabulary.tierDialHeader, "how much of your day to keep")
        XCTAssertEqual(LocationVocabulary.tierDialSubhead, "your day, your call. you can change this any time.")
        XCTAssertEqual(LocationVocabulary.lightLabel, "places only")
        XCTAssertEqual(LocationVocabulary.lightBody, "the places you stop — home, work, an event.")
        XCTAssertEqual(LocationVocabulary.balancedLabel, "places + comings and goings")
        XCTAssertEqual(LocationVocabulary.balancedBody, "your stops, plus the shape of how you move between them.")
        XCTAssertEqual(LocationVocabulary.balancedDefaultBadge, "recommended")
        XCTAssertEqual(LocationVocabulary.fullLabel, "the complete picture")
        XCTAssertEqual(LocationVocabulary.fullBody, "the full, detailed picture of where your day happened. uses more battery.")
        XCTAssertEqual(LocationVocabulary.batteryHonesty, "the fuller settings keep solstone aware in the background, which uses more battery. iOS shows its location arrow whenever location is on — that's iOS keeping you honest.")
        XCTAssertEqual(LocationVocabulary.alwaysBackgroundPrimer, "to keep this when solstone isn't open, iOS will ask to allow location \"Always.\" you can change it any time in iOS Settings.")
        XCTAssertEqual(LocationVocabulary.downgradeBodyTemplate, "you chose {tier}, but iOS is only sharing location while solstone is open. your journal will show the gaps honestly — solstone never fills them in.")
        XCTAssertEqual(LocationVocabulary.openSettingsAction, "open iOS Settings")
        XCTAssertEqual(LocationVocabulary.matchToAllowedAction, "match it to what's allowed")
        XCTAssertEqual(LocationVocabulary.restrictedBody, "location is turned off for solstone by a restriction on this device. solstone can't keep your day until that's lifted.")
        XCTAssertEqual(LocationVocabulary.honestGap, "gap here — location wasn't available.")
        XCTAssertEqual(LocationVocabulary.liveActivityText, "solstone is adding where your day happens")
        XCTAssertEqual(LocationVocabulary.deleteConfirmBody, "delete everything location added to your journal? this removes where your day happened. other things in your journal stay. this can't be undone.")
        XCTAssertEqual(LocationVocabulary.deleteConfirmButton, "delete location's contributions")
        XCTAssertEqual(LocationVocabulary.deleteReceiptHeadlineTemplate, "deleted. removed from your journal: where your day happened, across {N} days.")
    }

    func testDowngradeBodySubstitutesTierLabel() {
        XCTAssertEqual(
            LocationVocabulary.downgradeBody(tier: .balanced),
            "you chose places + comings and goings, but iOS is only sharing location while solstone is open. your journal will show the gaps honestly — solstone never fills them in."
        )
    }

    func testDeleteReceiptHeadlineSubstitutesDayCount() {
        XCTAssertEqual(
            LocationVocabulary.deleteReceiptHeadline(days: 4),
            "deleted. removed from your journal: where your day happened, across 4 days."
        )
    }
}
