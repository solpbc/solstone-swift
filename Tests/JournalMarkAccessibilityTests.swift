// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class JournalMarkAccessibilityTests: XCTestCase {
    func testSpokenValueUsesDecodedColorName() {
        let mark = Self.mark(color1: "amber", color2: "lime")
        XCTAssertEqual(
            JournalMarkAccessibility.spokenValue(mark: mark),
            "amber bug, lime gem, afoot, unfixed"
        )
        XCTAssertEqual(
            JournalMarkAccessibility.chipToken(colorName: "amber", glyphName: "bug"),
            "amber bug"
        )
#if DEBUG
        XCTAssertEqual(
            JournalMarkAccessibility.spokenValue(mark: .uiTestSample),
            "amber bug, lime gem, afoot, unfixed"
        )
#endif
    }

    func testSpokenValueFallsBackToGlyphNameWhenColorNameAbsent() {
        let mark = Self.mark(color1: nil, color2: nil)
        XCTAssertEqual(
            JournalMarkAccessibility.spokenValue(mark: mark),
            "bug, gem, afoot, unfixed"
        )
        XCTAssertEqual(JournalMarkAccessibility.chipToken(colorName: nil, glyphName: "bug"), "bug")
        XCTAssertEqual(JournalMarkAccessibility.chipToken(colorName: "  ", glyphName: "bug"), "bug")
        XCTAssertEqual(JournalMarkAccessibility.chipToken(colorName: "", glyphName: "gem"), "gem")
    }

    func testSpokenValueForNilIsGeneric() {
        XCTAssertEqual(
            JournalMarkAccessibility.spokenValue(mark: nil),
            "your journal, not set up yet"
        )
        XCTAssertEqual(JournalMarkGeneric.spokenValue, "your journal, not set up yet")
        XCTAssertEqual(JournalMarkGeneric.words, ["your", "journal"])
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: nil).contains("bug"))
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: nil).contains("gem"))
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: nil).contains("unavailable"))
    }

    func testDashGeometryScalesWithChipSide() {
        XCTAssertEqual(JournalMarkGeneric.dashOn(side: 27), 3.2, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.dashOff(side: 27), 2.4, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.dashOn(side: 64), 3.2 * 64 / 27, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.dashOff(side: 64), 2.4 * 64 / 27, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.fillOpacity, 0.07)
        XCTAssertEqual(JournalMarkGeneric.orangeHex, "#E8923A")
        XCTAssertEqual(JournalMarkGeneric.goldHex, "#D4A017")
    }

    func testJournalMarkViewUsesIgnoreAndSpokenValue() throws {
        let text = try Self.source("Sources/Pairing/JournalMark.swift")
        XCTAssertTrue(text.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(text.contains(".accessibilityValue(JournalMarkAccessibility.spokenValue(mark: self.mark))"))
        XCTAssertFalse(text.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(text.contains("JournalMarkTint"))
        XCTAssertFalse(text.contains("journalMarkUnavailable"))
    }

    func testGenericChipHasNoGlyph() throws {
        let text = try Self.source("Sources/Pairing/JournalMark.swift")
        let start = try XCTUnwrap(text.range(of: "private struct JournalMarkGenericChip"))
        let end = try XCTUnwrap(text.range(of: "private struct JournalMarkIconChip"))
        let chip = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(chip.contains("dash:"))
        XCTAssertTrue(chip.contains("JournalMarkGeneric.dashOn"))
        XCTAssertTrue(chip.contains("JournalMarkGeneric.dashOff"))
        XCTAssertFalse(chip.contains("GlyphShape"))
        XCTAssertFalse(chip.contains("GlyphParser"))
        XCTAssertFalse(chip.contains(".svg"))
        XCTAssertFalse(chip.contains("icon.svg"))
    }

    func testGenericMarkFileHasNoGlyph() throws {
        let text = try Self.source("Sources/Pairing/JournalMarkGeneric.swift")
        XCTAssertFalse(text.contains("GlyphShape"))
        XCTAssertFalse(text.contains("GlyphParser"))
        XCTAssertFalse(text.contains("unavailable"))
    }

    private static func mark(color1: String?, color2: String?) -> JournalMark {
        JournalMark(
            icon1: JournalMark.Icon(
                name: "bug",
                color: JournalMark.MarkColor(hex: "#f59e0b", name: color1),
                rot: 0,
                svg: #"<path d="M0 0" />"#
            ),
            icon2: JournalMark.Icon(
                name: "gem",
                color: JournalMark.MarkColor(hex: "#84cc16", name: color2),
                rot: 45,
                svg: #"<path d="M0 0" />"#
            ),
            words: ["afoot", "unfixed"]
        )
    }

    private static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
