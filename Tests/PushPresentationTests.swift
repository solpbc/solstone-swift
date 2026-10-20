// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class PushPresentationTests: XCTestCase {
    private func parseEntry(_ jsonString: String) throws -> Any {
        let data = jsonString.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data)
    }

    func testPushProofCountRendering() throws {
        let bundle = Bundle(for: PushEnvelope.self)
        let locale = Locale(identifier: "en_US")

        let countsAndExpectations: [(Int, String)] = [
            (0, "\u{2068}0\u{2069} items are ready."),
            (1, "\u{2068}1\u{2069} item is ready."),
            (2, "\u{2068}2\u{2069} items are ready."),
            (10000, "\u{2068}10000\u{2069} items are ready.")
        ]

        for (count, expected) in countsAndExpectations {
            let json = """
            {
                "v": 1,
                "catalog_epoch": 1,
                "code": "push.proof.count",
                "args": {"count": \(count)},
                "fallback_en": "fallback"
            }
            """
            let entry = try self.parseEntry(json)
            let rendered = PushPresentation.render(
                entry: entry,
                legacy: "legacy",
                locale: locale,
                bundle: bundle
            )
            XCTAssertEqual(rendered, expected)
            XCTAssertFalse(rendered.contains(","), "Count must not contain grouping separators")
        }
    }

    func testPushProofStateRendering() throws {
        let bundle = Bundle(for: PushEnvelope.self)
        let locale = Locale(identifier: "en_US")

        // Ready state
        let readyJson = """
        {
            "v": 1,
            "catalog_epoch": 1,
            "code": "push.proof.state",
            "args": {"state": "ready"},
            "fallback_en": "fallback"
        }
        """
        let readyEntry = try self.parseEntry(readyJson)
        let readyRendered = PushPresentation.render(
            entry: readyEntry,
            legacy: "legacy",
            locale: locale,
            bundle: bundle
        )
        XCTAssertEqual(readyRendered, "ready for the test.")

        // Unknown enum variant falls back to waiting
        let unknownJson = """
        {
            "v": 1,
            "catalog_epoch": 1,
            "code": "push.proof.state",
            "args": {"state": "unknown_variant"},
            "fallback_en": "fallback"
        }
        """
        let unknownEntry = try self.parseEntry(unknownJson)
        let unknownRendered = PushPresentation.render(
            entry: unknownEntry,
            legacy: "legacy",
            locale: locale,
            bundle: bundle
        )
        XCTAssertEqual(unknownRendered, "waiting for the test.")
    }

    func testInvalidCountValuesFallBack() throws {
        let bundle = Bundle(for: PushEnvelope.self)
        let locale = Locale(identifier: "en_US")

        let invalidCases: [String] = [
            """
            {
                "v": 1,
                "catalog_epoch": 1,
                "code": "push.proof.count",
                "args": {"count": true},
                "fallback_en": "fallback_bool"
            }
            """,
            """
            {
                "v": 1,
                "catalog_epoch": 1,
                "code": "push.proof.count",
                "args": {"count": "10"},
                "fallback_en": "fallback_string"
            }
            """,
            """
            {
                "v": 1,
                "catalog_epoch": 1,
                "code": "push.proof.count",
                "args": {"count": 10001},
                "fallback_en": "fallback_over_max"
            }
            """,
            """
            {
                "v": 1,
                "catalog_epoch": 1,
                "code": "push.proof.count",
                "args": {"count": -1},
                "fallback_en": "fallback_under_min"
            }
            """,
            """
            {
                "v": 1,
                "catalog_epoch": 1,
                "code": "push.proof.count",
                "args": {"count": 1.5},
                "fallback_en": "fallback_fraction"
            }
            """
        ]

        for json in invalidCases {
            let entry = try self.parseEntry(json)
            guard let dict = entry as? [String: Any],
                  let expectedFallback = dict["fallback_en"] as? String
            else {
                XCTFail("Invalid test json")
                continue
            }
            let rendered = PushPresentation.render(
                entry: entry,
                legacy: "legacy",
                locale: locale,
                bundle: bundle
            )
            XCTAssertEqual(rendered, expectedFallback)
        }
    }

    func testUnknownIdAndWireVersionMismatch() throws {
        let bundle = Bundle(for: PushEnvelope.self)
        let locale = Locale(identifier: "en_US")

        // Unknown id
        let unknownIdJson = """
        {
            "v": 1,
            "catalog_epoch": 1,
            "code": "push.not.a.catalog.id",
            "args": {},
            "fallback_en": "fallback_unknown_id"
        }
        """
        let unknownIdEntry = try self.parseEntry(unknownIdJson)
        XCTAssertEqual(
            PushPresentation.render(entry: unknownIdEntry, legacy: "legacy", locale: locale, bundle: bundle),
            "fallback_unknown_id"
        )

        // Wire version not 1
        let badVJson = """
        {
            "v": 2,
            "catalog_epoch": 1,
            "code": "push.proof.new",
            "args": {},
            "fallback_en": "fallback_bad_v"
        }
        """
        let badVEntry = try self.parseEntry(badVJson)
        XCTAssertEqual(
            PushPresentation.render(entry: badVEntry, legacy: "legacy", locale: locale, bundle: bundle),
            "fallback_bad_v"
        )

        // Catalog epoch not 1
        let badEpochJson = """
        {
            "v": 1,
            "catalog_epoch": 2,
            "code": "push.proof.new",
            "args": {},
            "fallback_en": "fallback_bad_epoch"
        }
        """
        let badEpochEntry = try self.parseEntry(badEpochJson)
        XCTAssertEqual(
            PushPresentation.render(entry: badEpochEntry, legacy: "legacy", locale: locale, bundle: bundle),
            "fallback_bad_epoch"
        )
    }

    func testLocaleFallbackToPackagedLocalization() throws {
        let bundle = Bundle(for: PushEnvelope.self)
        let frenchLocale = Locale(identifier: "fr_FR")

        let json = """
        {
            "v": 1,
            "catalog_epoch": 1,
            "code": "push.proof.new",
            "args": {},
            "fallback_en": "distinct fallback string"
        }
        """
        let entry = try self.parseEntry(json)
        let rendered = PushPresentation.render(
            entry: entry,
            legacy: "legacy",
            locale: frenchLocale,
            bundle: bundle
        )
        XCTAssertEqual(rendered, "a new test message is ready.")
        XCTAssertNotEqual(rendered, "distinct fallback string")
        XCTAssertNotEqual(rendered, "legacy")

        let countZeroJson = """
        {
            "v": 1,
            "catalog_epoch": 1,
            "code": "push.proof.count",
            "args": {"count": 0},
            "fallback_en": "distinct fallback string"
        }
        """
        let countZeroEntry = try self.parseEntry(countZeroJson)
        let countZeroRendered = PushPresentation.render(
            entry: countZeroEntry,
            legacy: "legacy",
            locale: frenchLocale,
            bundle: bundle
        )
        XCTAssertEqual(countZeroRendered, "\u{2068}0\u{2069} items are ready.")
        XCTAssertNotEqual(countZeroRendered, "\u{2068}0\u{2069} item is ready.")
    }
}
