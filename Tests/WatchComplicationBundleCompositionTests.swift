// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchComplicationBundleCompositionTests: XCTestCase {
    func testBundleRegistersRectangularSmartStackWidget() throws {
        let source = try String(
            contentsOf: Self.worktreeRoot().appendingPathComponent(
                "SolstoneWatchComplication/SolstoneWatchComplication.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("SolstoneWatchStatusSmartStackWidget()"))
        XCTAssertTrue(source.contains("kind: SolstoneWatchStatusSmartStack.widgetKind"))
        XCTAssertTrue(source.contains("SolstoneWatchComplicationView(entry: entry)"))
        XCTAssertTrue(source.contains(".supportedFamilies([.accessoryRectangular])"))
    }

    private static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
