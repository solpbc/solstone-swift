// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class JournalMarkTintTests: XCTestCase {
    func testSampleChipsAndUnknownFallback() {
        XCTAssertEqual(JournalMarkTint.word(hex: "#f59e0b"), "amber")
        XCTAssertEqual(JournalMarkTint.word(hex: "#84cc16"), "lime")
        XCTAssertEqual(JournalMarkTint.word(hex: "#F59E0B"), "amber")
        XCTAssertEqual(JournalMarkTint.word(hex: "#000000"), "tint")
        XCTAssertEqual(JournalMarkTint.chipToken(hex: "#f59e0b", glyphName: "bug"), "amber bug")
        XCTAssertEqual(JournalMarkTint.chipToken(hex: "#84cc16", glyphName: "gem"), "lime gem")
    }

    func testSpokenValueOrderAndNilUnavailable() {
        XCTAssertEqual(
            JournalMarkTint.spokenValue(mark: .uiTestSample),
            "amber bug, lime gem, afoot, unfixed"
        )
        XCTAssertEqual(JournalMarkTint.spokenValue(mark: nil), SourceVocabulary.journalMarkUnavailable)
        XCTAssertFalse(JournalMarkTint.spokenValue(mark: nil).contains("bug"))
        XCTAssertFalse(JournalMarkTint.spokenValue(mark: nil).contains("gem"))
    }

    func testJournalMarkViewUsesIgnoreAndValue() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Pairing/JournalMark.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(text.contains(".accessibilityValue(JournalMarkTint.spokenValue(mark: self.mark))"))
        XCTAssertFalse(text.contains(".accessibilityElement(children: .combine)"))
    }
}
