// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchComplicationRenderingGrepTests: XCTestCase {
    func testComplicationUsesAccessoryBackgroundAndAccentableImages() throws {
        let text = try Self.complicationSourceText()

        XCTAssertTrue(text.contains("AccessoryWidgetBackground"))
        XCTAssertTrue(text.contains("widgetAccentable"))
    }

    func testComplicationDoesNotUseLegacyCircleFallbacks() throws {
        let text = try Self.complicationSourceText()

        XCTAssertFalse(text.contains("Circle()"))
        XCTAssertFalse(text.contains("fallbackSnapshot"))
    }

    private static func complicationSourceText() throws -> String {
        let path = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("SolstoneWatchComplication/SolstoneWatchComplication.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }
}
