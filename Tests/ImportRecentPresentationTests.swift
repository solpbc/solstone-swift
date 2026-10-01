// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ImportRecentPresentationTests: XCTestCase {
    func testPendingCountUsesSendingProgressAndWinsOverFailures() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 1,
                lastDeliveredAt: nil,
                failedCount: 1,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.shareSendingProgress
        )
    }

    func testLastDeliveredAtUsesDeliveredProgressAndWinsOverFailures() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 1,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.shareDeliveredProgress
        )
    }

    func testFailedCountUsesWaitingCopyNotNeedsAttention() {
        let text = ImportRecentPresentation.recentText(
            pendingCount: 0,
            lastDeliveredAt: nil,
            failedCount: 1,
            awaitingMarkConfirmation: false,
            connectionStatus: .connectedIdle,
            isStalled: false
        )

        XCTAssertEqual(text, SourceVocabulary.onThisPhoneWaitingExplain)
        XCTAssertNotEqual(text, SourceVocabulary.needsAttentionSubtext)
    }

    func testEmptyRecentTextUsesRecentEmpty() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: nil,
                failedCount: 0,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.recentEmpty
        )
    }

    func testAwaitingMarkConfirmationRecentText() {
        // Pending > 0
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 1,
                lastDeliveredAt: nil,
                failedCount: 0,
                awaitingMarkConfirmation: true,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.awaitingMarkConfirmationLine
        )

        // Failed > 0 (without lastDeliveredAt)
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: nil,
                failedCount: 1,
                awaitingMarkConfirmation: true,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.awaitingMarkConfirmationLine
        )

        // Last delivered wins when pending is 0
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 1,
                awaitingMarkConfirmation: true,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.shareDeliveredProgress
        )

        // Empty
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: nil,
                failedCount: 0,
                awaitingMarkConfirmation: true,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.recentEmpty
        )
    }
}
