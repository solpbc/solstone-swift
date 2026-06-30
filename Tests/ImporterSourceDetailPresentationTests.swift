// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ImporterSourceDetailPresentationTests: XCTestCase {
    func testPendingCountUsesSendingProgressAndWinsOverFailures() {
        XCTAssertEqual(
            ImporterSourceDetailPresentation.recentText(
                pendingCount: 1,
                lastDeliveredAt: nil,
                failedCount: 1
            ),
            SourceVocabulary.shareSendingProgress
        )
    }

    func testLastDeliveredAtUsesDeliveredProgressAndWinsOverFailures() {
        XCTAssertEqual(
            ImporterSourceDetailPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 1
            ),
            SourceVocabulary.shareDeliveredProgress
        )
    }

    func testFailedCountUsesWaitingCopyNotNeedsAttention() {
        let text = ImporterSourceDetailPresentation.recentText(
            pendingCount: 0,
            lastDeliveredAt: nil,
            failedCount: 1
        )

        XCTAssertEqual(text, SourceVocabulary.onThisPhoneWaitingExplain)
        XCTAssertNotEqual(text, SourceVocabulary.needsAttentionSubtext)
    }

    func testEmptyRecentTextUsesRecentEmpty() {
        XCTAssertEqual(
            ImporterSourceDetailPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: nil,
                failedCount: 0
            ),
            SourceVocabulary.recentEmpty
        )
    }
}
