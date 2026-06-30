// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class DiagnosticsFiltersTests: XCTestCase {
    @MainActor
    func testProblemsOnlyPredicateComposesWithCategories() {
        let info = DiagnosticEvent(category: .upload, severity: .info, message: "info")
        let warning = DiagnosticEvent(category: .upload, severity: .warning, message: "warning")
        let error = DiagnosticEvent(category: .upload, severity: .error, message: "error")
        let excludedCategory = DiagnosticEvent(category: .voice, severity: .error, message: "voice")

        XCTAssertFalse(DiagnosticsEventFilter.matches(info, categories: [.upload], problemsOnly: true))
        XCTAssertTrue(DiagnosticsEventFilter.matches(warning, categories: [.upload], problemsOnly: true))
        XCTAssertTrue(DiagnosticsEventFilter.matches(error, categories: [.upload], problemsOnly: true))
        XCTAssertTrue(DiagnosticsEventFilter.matches(info, categories: [.upload], problemsOnly: false))
        XCTAssertTrue(DiagnosticsEventFilter.matches(warning, categories: [.upload], problemsOnly: false))
        XCTAssertTrue(DiagnosticsEventFilter.matches(error, categories: [.upload], problemsOnly: false))
        XCTAssertFalse(DiagnosticsEventFilter.matches(excludedCategory, categories: [.upload], problemsOnly: false))
        XCTAssertFalse(DiagnosticsEventFilter.matches(excludedCategory, categories: [.upload], problemsOnly: true))
    }

    @MainActor
    func testFailedSegmentPresentationCopyAndVisibility() throws {
        XCTAssertNil(FailedSegmentSection.presentation(failedTotal: 0, isConnected: true))

        let singular = try XCTUnwrap(FailedSegmentSection.presentation(failedTotal: 1, isConnected: true))
        XCTAssertEqual(
            singular,
            FailedSegmentPresentation(
                headline: "1 segment hasn't reached your journal",
                subtext: "they'll try again automatically the next time you reconnect.",
                showsButton: true
            )
        )

        let plural = try XCTUnwrap(FailedSegmentSection.presentation(failedTotal: 3, isConnected: true))
        XCTAssertEqual(
            plural,
            FailedSegmentPresentation(
                headline: "3 segments haven't reached your journal",
                subtext: "they'll try again automatically the next time you reconnect.",
                showsButton: true
            )
        )

        let offline = try XCTUnwrap(FailedSegmentSection.presentation(failedTotal: 2, isConnected: false))
        XCTAssertEqual(
            offline,
            FailedSegmentPresentation(
                headline: "2 segments haven't reached your journal",
                subtext: "you're offline — these will try again automatically when you reconnect.",
                showsButton: false
            )
        )
    }

    func testLifecycleWaitingLabelDoesNotUseNeedsAttentionCopy() {
        XCTAssertNotEqual(SourceVocabulary.waitingToSync, SourceVocabulary.needsAttention)
        XCTAssertEqual(SourceVocabulary.waitingToSync, "waiting to sync")
    }
}
