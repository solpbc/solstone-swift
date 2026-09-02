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
        let excludedCategory = DiagnosticEvent(category: .network, severity: .error, message: "network")

        XCTAssertFalse(DiagnosticsEventFilter.matches(info, categories: [.upload], problemsOnly: true))
        XCTAssertTrue(DiagnosticsEventFilter.matches(warning, categories: [.upload], problemsOnly: true))
        XCTAssertTrue(DiagnosticsEventFilter.matches(error, categories: [.upload], problemsOnly: true))
        XCTAssertTrue(DiagnosticsEventFilter.matches(info, categories: [.upload], problemsOnly: false))
        XCTAssertTrue(DiagnosticsEventFilter.matches(warning, categories: [.upload], problemsOnly: false))
        XCTAssertTrue(DiagnosticsEventFilter.matches(error, categories: [.upload], problemsOnly: false))
        XCTAssertFalse(DiagnosticsEventFilter.matches(excludedCategory, categories: [.upload], problemsOnly: false))
        XCTAssertFalse(DiagnosticsEventFilter.matches(excludedCategory, categories: [.upload], problemsOnly: true))
    }

    func testLifecycleWaitingLabelDoesNotUseNeedsAttentionCopy() {
        XCTAssertNotEqual(SourceVocabulary.waitingToSync, SourceVocabulary.needsAttention)
        XCTAssertEqual(SourceVocabulary.waitingToSync, "waiting to sync")
    }
}
