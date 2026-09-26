// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SourceDetailPresentationTests: XCTestCase {
    func testModeExplanationUsesSourceVocabulary() {
        XCTAssertEqual(
            SourceDetailPresentation.modeExplanation,
            "meeting keeps going until you stop it. voice memo stops on its own when you go quiet for a few seconds."
        )
        XCTAssertEqual(SourceDetailPresentation.modeExplanation, SourceVocabulary.modeExplanation)
    }

    func testElapsedLineIsTheTimeAloneBecauseTheVerdictAlreadySaysOn() {
        let formatted = String(format: "%02d:%02d", 134 / 60, 134 % 60)

        XCTAssertEqual(SourceDetailPresentation.elapsedLine(formatted: formatted), "02:14")
        XCTAssertEqual(SourceDetailPresentation.elapsedAccessibilityLabel(formatted: formatted), "on for 02:14")
    }

    func testAudioDeliverySummaryNamesRecordingsNotLocationUpdates() {
        XCTAssertEqual(AudioDetailPresentation.deliverySummary(pending: 1, failed: 0).line, "1 recording on the way to your journal.")
        XCTAssertEqual(AudioDetailPresentation.deliverySummary(pending: 3, failed: 0).line, "3 recordings on the way to your journal.")
        XCTAssertEqual(AudioDetailPresentation.deliverySummary(pending: 2, failed: 1).line, "1 recording needs attention.")
        XCTAssertEqual(AudioDetailPresentation.deliverySummary(pending: 0, failed: 2).line, "2 recordings need attention.")
        XCTAssertEqual(AudioDetailPresentation.deliverySummary(pending: 0, failed: 0).line, "nothing waiting right now.")
    }

    func testActiveSourceStateLabelStaysOn() {
        XCTAssertEqual(SourceState.active.label, "on")
    }
}
