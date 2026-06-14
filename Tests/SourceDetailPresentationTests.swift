// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SourceDetailPresentationTests: XCTestCase {
    func testModeExplanationUsesSourceVocabulary() {
        XCTAssertEqual(
            SourceDetailPresentation.modeExplanation,
            "Meeting keeps going until you stop it. Voice memo stops on its own when you go quiet for a few seconds."
        )
        XCTAssertEqual(SourceDetailPresentation.modeExplanation, SourceVocabulary.modeExplanation)
    }

    func testListeningIndicatorUsesSourceVocabulary() {
        XCTAssertEqual(SourceDetailPresentation.listeningIndicatorWord, SourceVocabulary.observerActiveSubtext)
        XCTAssertEqual(SourceDetailPresentation.listeningIndicatorWord, "listening")
    }

    func testElapsedLinePrefixesFormattedTime() {
        let formatted = String(format: "%02d:%02d", 134 / 60, 134 % 60)

        XCTAssertEqual(SourceDetailPresentation.elapsedLine(formatted: formatted), "listening · 02:14")
    }

    func testActiveSourceStateLabelStaysOn() {
        XCTAssertEqual(SourceState.active.label, "on")
    }
}
