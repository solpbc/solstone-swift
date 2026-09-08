// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SourcesViewRowBuilderTests: XCTestCase {
    func testAddMoreRowsOmitUnsupportedWatchRow() {
        let rows = SourcesViewRowBuilder.addMoreRows(
            audio: Self.source(id: "audio", kind: .observer),
            location: Self.source(id: "location", kind: .location),
            screencast: Self.source(id: "screencast", kind: .screencast),
            watch: nil,
            hiddenIDs: []
        )

        XCTAssertEqual(rows.map(\.route), [.audio, .location, .screencast])
        XCTAssertFalse(rows.contains { $0.route == .watch })
        XCTAssertFalse(rows.contains { $0.source.id == "watch" })
    }

    func testWatchSourceFromLaneOmitsUnsupportedAndBuildsNonUnsupportedSource() throws {
        XCTAssertNil(watchSourceModel(from: .unsupported, isJournalPaired: true))

        let source = try XCTUnwrap(watchSourceModel(from: .readyToSetUp(.installApp), isJournalPaired: true))

        XCTAssertEqual(source.id, "watch")
        XCTAssertEqual(source.kind, .watch)
        XCTAssertEqual(source.state, .readyToSetUp)
        XCTAssertEqual(source.subtextOverride, SourceVocabulary.watchReadyToSetUpSubtext)
    }

    func testAddMoreRowsKeepWatchOrderWhenPresent() {
        let rows = SourcesViewRowBuilder.addMoreRows(
            audio: Self.source(id: "audio", kind: .observer),
            location: Self.source(id: "location", kind: .location),
            screencast: Self.source(id: "screencast", kind: .screencast),
            watch: Self.source(id: "watch", kind: .watch),
            hiddenIDs: []
        )

        XCTAssertEqual(rows.map(\.route), [.audio, .location, .screencast, .watch])
    }

    func testAddMoreRowsPutHiddenFirstInCanonicalOrder() {
        let rows = SourcesViewRowBuilder.addMoreRows(
            audio: Self.source(id: "audio", kind: .observer),
            location: Self.source(id: "location", kind: .location),
            screencast: Self.source(id: "screencast", kind: .screencast),
            watch: Self.source(id: "watch", kind: .watch),
            hiddenIDs: ["screencast", "audio"]
        )

        XCTAssertEqual(rows.map(\.source.id), ["audio", "screencast", "location", "watch"])
    }

    func testAddMoreRowsOmitShareAndHaveNoSwitch() throws {
        let text = try String(contentsOf: Self.addMoreViewURL(), encoding: .utf8)
        XCTAssertFalse(text.contains("Toggle"))
        XCTAssertFalse(text.contains("share-sheet"))
        XCTAssertFalse(text.contains("SourceHomeTileControl"))
    }
}

private extension SourcesViewRowBuilderTests {
    static func source(id: String, kind: SourceKind) -> Source {
        Source(
            id: id,
            displayName: id,
            kind: kind,
            state: .off,
            isJournalPaired: true,
            activeSubtext: "on",
            attention: nil,
            pendingStatus: .nonePending
        )
    }

    static func addMoreViewURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Home/AddMoreView.swift")
    }
}
