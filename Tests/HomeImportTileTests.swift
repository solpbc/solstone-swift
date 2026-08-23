// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class HomeImportTileTests: XCTestCase {
    func testImportTileCopyAndNoStateWord() throws {
        let text = try Self.contents("Sources/Home/HomeSourceTile.swift")
        let tile = try Self.section(in: text, from: "struct HomeImportTile: View {", to: "\n}")
        XCTAssertTrue(tile.contains("SourceVocabulary.importTitle"))
        XCTAssertTrue(tile.contains("SourceVocabulary.importSubline"))
        XCTAssertTrue(tile.contains("dayHome.importEntry"))
        XCTAssertFalse(tile.contains("state.label"))
        XCTAssertFalse(tile.contains("Toggle"))
        XCTAssertFalse(tile.contains("share sheet"))
        XCTAssertTrue(tile.contains("ShellDestination.import"))
    }

    func testShareSheetCopyLivesOnlyOnImportScreen() throws {
        let home = try Self.contents("Sources/Home/HomeSourceTile.swift")
        let addMore = try Self.contents("Sources/Home/AddMoreView.swift")
        let dayHome = try Self.contents("Sources/Home/DayHomeView.swift")
        XCTAssertFalse(home.contains("share sheet"))
        XCTAssertFalse(addMore.contains("share sheet"))
        XCTAssertFalse(dayHome.contains("share sheet"))
        let importView = try Self.contents("Sources/Home/ImportView.swift")
        XCTAssertTrue(importView.contains("shareAlwaysOnExplainer"))
    }

    func testWatchDetailHasNoSwitchAndNoSyncNow() throws {
        let text = try Self.contents("Sources/WatchCapture/WatchSourceDetailView.swift")
        XCTAssertFalse(text.contains("Toggle"))
        XCTAssertFalse(text.contains("sync now"))
        XCTAssertFalse(text.contains("sync-now"))
    }
}

private extension HomeImportTileTests {
    static func contents(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func section(in text: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start))
        return String(text[startRange.lowerBound...])
    }
}
