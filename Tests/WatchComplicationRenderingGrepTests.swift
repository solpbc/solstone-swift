// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchComplicationRenderingGrepTests: XCTestCase {
    func testComplicationUsesAccessoryBackgroundAndAccentableImages() throws {
        let text = try Self.complicationSourceText()
        let lines = text.components(separatedBy: .newlines)
        let startIndex = try XCTUnwrap(lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespaces) == "var circularView: some View {"
        })
        let propertyIndent = Self.leadingSpaceCount(in: lines[startIndex])
        let endIndex = try XCTUnwrap(lines[(startIndex + 1)...].firstIndex { line in
            Self.leadingSpaceCount(in: line) == propertyIndent
                && line.trimmingCharacters(in: .whitespaces) == "}"
        })
        let circularLines = lines[startIndex...endIndex]
        let backgroundLine = try XCTUnwrap(circularLines.first { line in
            line.contains("AccessoryWidgetBackground()")
        })
        let backgroundIndent = Self.leadingSpaceCount(in: backgroundLine)
        let accentableLines = circularLines.filter { line in
            line.contains(".widgetAccentable()")
        }

        XCTAssertTrue(text.contains("AccessoryWidgetBackground"))
        XCTAssertFalse(accentableLines.isEmpty)
        // The accent belongs on the image chain. A shallower or equal indent wraps an
        // enclosing scope that includes the accessory background.
        XCTAssertTrue(accentableLines.allSatisfy { line in
            Self.leadingSpaceCount(in: line) > backgroundIndent
        })
    }

    func testComplicationDoesNotUseLegacyCircleFallbacks() throws {
        let text = try Self.complicationSourceText()

        XCTAssertFalse(text.contains("Circle()"))
        XCTAssertFalse(text.contains("fallbackSnapshot"))
    }

    func testComplicationTreatsMissingSnapshotAsOptional() throws {
        let text = try Self.complicationSourceText()

        // The provider lives in the watchOS extension target, outside this test target, so absence of
        // a fabricated snapshot is asserted structurally on the source text.
        XCTAssertTrue(text.contains("let snapshot: WatchComplicationSnapshot?"))
        XCTAssertTrue(text.contains("-> WatchComplicationSnapshot?"))
    }

    private static func complicationSourceText() throws -> String {
        let path = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("SolstoneWatchComplication/SolstoneWatchComplication.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private static func leadingSpaceCount(in line: String) -> Int {
        line.prefix { character in
            character == " "
        }.count
    }
}
