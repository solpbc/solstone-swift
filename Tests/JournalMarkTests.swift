// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class JournalMarkTests: XCTestCase {
    func testDecodeAndValidateAcceptsSample() throws {
        let mark = try XCTUnwrap(Self.decodeAndValidate(Self.sampleData()))

        XCTAssertEqual(mark.icon1.name, "bug")
        XCTAssertEqual(mark.icon2.name, "gem")
        XCTAssertEqual(mark.icon1.rot, 0)
        XCTAssertEqual(mark.icon2.rot, 45)
        XCTAssertEqual(mark.words, ["afoot", "unfixed"])
    }

    func testDecodeAndValidateReturnsNilForOneIcon() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(includeIcon2: false)))
    }

    func testValidateRejectsThreeWords() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(words: ["afoot", "unfixed", "extra"])))
    }

    func testValidateRejectsMissingHashHex() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(icon1Color: "f59e0b")))
    }

    func testValidateRejectsShortHex() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(icon1Color: "#f59e0")))
    }

    func testValidateRejectsRotNinety() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(icon2Rot: 90)))
    }

    func testValidateRejectsRotNegativeFortyFive() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(icon2Rot: -45)))
    }

    func testValidateRejectsEmptySVG() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(icon1SVG: "")))
    }

    func testValidateRejectsUnsupportedGlyphCommand() {
        XCTAssertNil(Self.decodeAndValidate(Self.sampleData(icon1SVG: #"<path d="M0 0 R1 1" />"#)))
    }

    static func decodeAndValidate(_ data: Data) -> JournalMark? {
        guard let decoded = try? JSONDecoder().decode(JournalMark.self, from: data) else {
            return nil
        }
        return JournalMark.validate(decoded)
    }

    static func sampleData(
        includeIcon2: Bool = true,
        icon1Color: String = "#f59e0b",
        icon1SVG: String = JournalMark.uiTestSample.icon1.svg,
        icon2Rot: Int = 45,
        words: [String] = ["afoot", "unfixed"]
    ) -> Data {
        var root: [String: Any] = [
            "icon1": [
                "name": "bug",
                "color": ["hex": icon1Color],
                "rot": 0,
                "svg": icon1SVG,
            ],
            "words": words,
        ]
        if includeIcon2 {
            root["icon2"] = [
                "name": "gem",
                "color": ["hex": "#84cc16"],
                "rot": icon2Rot,
                "svg": JournalMark.uiTestSample.icon2.svg,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }
}
