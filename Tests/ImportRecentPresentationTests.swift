// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ImportRecentPresentationTests: XCTestCase {
    func testFailuresWinOverPendingAndLastDeliveredAt() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 1,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 1,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            AppStrings.ios_app_importstatusleadattention()
        )
    }

    func testLastDeliveredAtNeverShadowsFailures() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 1,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            AppStrings.ios_app_importstatusleadattention()
        )
    }

    func testLastDeliveredAtNeverShadowsReadyToReview() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 0,
                readyToReviewCount: 1,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            AppStrings.ios_app_importtilereadytoreview()
        )
    }

    func testPendingUsesSendingProgressWhenNoFailuresOrReview() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 1,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 0,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.shareSendingProgress
        )
    }

    func testLastDeliveredAtShowsDeliveredOnlyWhenIdle() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 0,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.shareDeliveredProgress
        )
    }

    func testEmptyRecentTextUsesImportRecentEmpty() {
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: nil,
                failedCount: 0,
                awaitingMarkConfirmation: false,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            AppStrings.ios_app_importrecentempty()
        )
    }

    func testAwaitingMarkConfirmationNeverShadowsFailuresOrReview() {
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

        // Failed > 0 even when lastDeliveredAt != nil
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 1,
                awaitingMarkConfirmation: true,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.awaitingMarkConfirmationLine
        )

        // Ready to review even when lastDeliveredAt != nil
        XCTAssertEqual(
            ImportRecentPresentation.recentText(
                pendingCount: 0,
                lastDeliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                failedCount: 0,
                readyToReviewCount: 1,
                awaitingMarkConfirmation: true,
                connectionStatus: .connectedIdle,
                isStalled: false
            ),
            SourceVocabulary.awaitingMarkConfirmationLine
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
            AppStrings.ios_app_importrecentempty()
        )
    }
}
