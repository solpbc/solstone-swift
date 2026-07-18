// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneFirstContactTests: XCTestCase {
    func testEmptyInviteBranchExcludesJournalTruthForPairedWelcomeFraming() {
        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: true, hasWelcomeFraming: true),
            .invite(includesJournalTruth: false)
        )
        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: true, hasWelcomeFraming: false),
            .allQuiet
        )
    }

    func testEmptyInviteBranchIncludesJournalTruthWhenUnpaired() {
        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: false, hasWelcomeFraming: false),
            .invite(includesJournalTruth: true)
        )
        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: false, hasWelcomeFraming: true),
            .invite(includesJournalTruth: true)
        )
    }

    func testMagicMomentCandidateUsesFirstItemFromAnySource() {
        let share = Self.item(id: "share", sourceKind: .share, itemTime: Date(timeIntervalSince1970: 20))
        let location = Self.item(id: "location", sourceKind: .location, itemTime: Date(timeIntervalSince1970: 10))
        let snapshot = OnThisPhoneAggregateSnapshot(
            sources: [],
            items: [share, location]
        )

        XCTAssertEqual(
            magicMomentShownCandidate(
                from: snapshot,
                magicMomentFirstSeen: false,
                magicMomentDismissed: false,
                hasCurrentMagicMomentItem: false,
                isObserverPermissionDenied: false
            ),
            share
        )
    }

    func testFreshInstallFirstItemStillShowsMagicMoment() {
        let markedFirstSeenOnLaunch = shouldMarkMagicMomentFirstSeenOnLaunch(
            magicMomentFirstSeen: false,
            hasExistingOnThisPhoneItems: false,
            isUITest: false
        )
        XCTAssertFalse(markedFirstSeenOnLaunch)

        let firstItem = Self.item(id: "omi", sourceKind: .audio)
        let snapshot = OnThisPhoneAggregateSnapshot(
            sources: [],
            items: [firstItem]
        )

        XCTAssertEqual(
            magicMomentShownCandidate(
                from: snapshot,
                magicMomentFirstSeen: markedFirstSeenOnLaunch,
                magicMomentDismissed: false,
                hasCurrentMagicMomentItem: false,
                isObserverPermissionDenied: false
            ),
            firstItem
        )
    }

    func testMagicMomentCandidateRespectsExistingSuppressors() {
        let snapshot = OnThisPhoneAggregateSnapshot(
            sources: [],
            items: [Self.item(id: "location", sourceKind: .location)]
        )

        XCTAssertNil(magicMomentShownCandidate(
            from: snapshot,
            magicMomentFirstSeen: true,
            magicMomentDismissed: false,
            hasCurrentMagicMomentItem: false,
            isObserverPermissionDenied: false
        ))
        XCTAssertNil(magicMomentShownCandidate(
            from: snapshot,
            magicMomentFirstSeen: false,
            magicMomentDismissed: true,
            hasCurrentMagicMomentItem: false,
            isObserverPermissionDenied: false
        ))
        XCTAssertNil(magicMomentShownCandidate(
            from: snapshot,
            magicMomentFirstSeen: false,
            magicMomentDismissed: false,
            hasCurrentMagicMomentItem: true,
            isObserverPermissionDenied: false
        ))
        XCTAssertNil(magicMomentShownCandidate(
            from: snapshot,
            magicMomentFirstSeen: false,
            magicMomentDismissed: false,
            hasCurrentMagicMomentItem: false,
            isObserverPermissionDenied: true
        ))
    }

    private static func item(
        id: String,
        sourceKind: OnThisPhoneSourceKind,
        itemTime: Date = Date(timeIntervalSince1970: 1)
    ) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: id,
            sourceKind: sourceKind,
            sendState: .savedOnThisPhone,
            contentType: nil,
            filename: nil,
            bytes: nil,
            originApp: nil,
            basis: nil,
            itemTime: itemTime,
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: nil
        )
    }
}
