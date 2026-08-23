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
        XCTAssertNil(mark.icon1.color.name)
        XCTAssertNil(mark.icon2.color.name)
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

    func testDecodeColorNameIsOptionalAndIgnoredByValidate() throws {
        let unnamed = try JSONDecoder().decode(JournalMark.self, from: Self.sampleData())
        XCTAssertNil(unnamed.icon1.color.name)
        XCTAssertNil(unnamed.icon2.color.name)
        XCTAssertNotNil(JournalMark.validate(unnamed))

        let named = try JSONDecoder().decode(
            JournalMark.self,
            from: Self.sampleData(icon1ColorName: "amber", icon2ColorName: "lime")
        )
        XCTAssertEqual(named.icon1.color.name, "amber")
        XCTAssertEqual(named.icon2.color.name, "lime")
        XCTAssertNotNil(JournalMark.validate(named))
    }

    func testValidateSourceDoesNotReadColorName() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Pairing/JournalMark.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(text.range(of: "static func validate(_ mark: JournalMark)"))
        let end = try XCTUnwrap(text.range(of: "private static func isValidHexColor"))
        let validate = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(validate.contains("color.name"))
        XCTAssertFalse(validate.contains(".name"))
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
        icon1ColorName: String? = nil,
        icon1SVG: String = JournalMark.uiTestSample.icon1.svg,
        icon2Rot: Int = 45,
        icon2ColorName: String? = nil,
        words: [String] = ["afoot", "unfixed"]
    ) -> Data {
        var icon1ColorObject: [String: Any] = ["hex": icon1Color]
        if let icon1ColorName {
            icon1ColorObject["name"] = icon1ColorName
        }
        var root: [String: Any] = [
            "icon1": [
                "name": "bug",
                "color": icon1ColorObject,
                "rot": 0,
                "svg": icon1SVG,
            ],
            "words": words,
        ]
        if includeIcon2 {
            var icon2ColorObject: [String: Any] = ["hex": "#84cc16"]
            if let icon2ColorName {
                icon2ColorObject["name"] = icon2ColorName
            }
            root["icon2"] = [
                "name": "gem",
                "color": icon2ColorObject,
                "rot": icon2Rot,
                "svg": JournalMark.uiTestSample.icon2.svg,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }
}
