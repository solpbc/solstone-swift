// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class JournalMarkAccessibilityTests: XCTestCase {
    func testSpokenValueUsesDecodedColorNamesWhenBothPresent() {
        let mark = Self.mark(color1: "amber", color2: "lime")
        XCTAssertEqual(
            JournalMarkAccessibility.spokenValue(mark: mark),
            "amber, lime, afoot, unfixed"
        )
#if DEBUG
        XCTAssertEqual(
            JournalMarkAccessibility.spokenValue(mark: .uiTestSample),
            "amber, lime, afoot, unfixed"
        )
#endif
    }

    func testSpokenValueFallsBackToWordsWhenEitherColorNameAbsentOrBlank() {
        let nameless = Self.mark(color1: nil, color2: nil)
        XCTAssertEqual(JournalMarkAccessibility.spokenValue(mark: nameless), "afoot, unfixed")
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: nameless).contains("bug"))
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: nameless).contains("gem"))

        let blank1 = Self.mark(color1: "  ", color2: "lime")
        XCTAssertEqual(JournalMarkAccessibility.spokenValue(mark: blank1), "afoot, unfixed")
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: blank1).contains("bug"))
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: blank1).contains("gem"))

        let blank2 = Self.mark(color1: "amber", color2: "")
        XCTAssertEqual(JournalMarkAccessibility.spokenValue(mark: blank2), "afoot, unfixed")
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: blank2).contains("bug"))
        XCTAssertFalse(JournalMarkAccessibility.spokenValue(mark: blank2).contains("gem"))
    }

    func testGenericAndUnavailableSpokenValues() {
        XCTAssertEqual(JournalMarkGeneric.spokenValue, "your journal, not set up yet")
        XCTAssertEqual(JournalIdentity.generic.spokenValue, JournalMarkGeneric.spokenValue)
        XCTAssertEqual(JournalIdentity.unavailable.spokenValue, JournalIdentity.unavailableSpokenValue)
        XCTAssertEqual(JournalMarkGeneric.words, ["your", "journal"])
    }

    func testDashGeometryScalesWithChipSide() {
        XCTAssertEqual(JournalMarkGeneric.dashOn(side: 27), 3.2, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.dashOff(side: 27), 2.4, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.dashOn(side: 64), 3.2 * 64 / 27, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.dashOff(side: 64), 2.4 * 64 / 27, accuracy: 0.0001)
        XCTAssertEqual(JournalMarkGeneric.fillOpacity, 0.07)
        XCTAssertEqual(JournalMarkGeneric.orangeHex, "#E8913A")
        XCTAssertEqual(JournalMarkGeneric.goldHex, "#D4A017")
    }

    func testJournalMarkViewUsesIgnoreAndSpokenValue() throws {
        let text = try Self.source("Sources/Pairing/JournalMark.swift")
        XCTAssertTrue(text.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(text.contains("spokenValue"))
        XCTAssertFalse(text.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(text.contains("JournalMarkTint"))
    }

    func testGenericChipHasNoGlyph() throws {
        let text = try Self.source("Sources/Pairing/JournalMark.swift")
        let start = try XCTUnwrap(text.range(of: "struct JournalMarkGenericChip"))
        let end = try XCTUnwrap(text.range(of: "struct JournalMarkIconChip"))
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
