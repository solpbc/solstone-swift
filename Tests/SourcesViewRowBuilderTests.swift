// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SourcesViewRowBuilderTests: XCTestCase {
    func testPrimaryRowsOmitUnsupportedWatchRow() {
        let rows = SourcesViewRowBuilder.primaryRows(
            audio: Self.source(id: "audio", kind: .observer),
            location: Self.source(id: "location", kind: .location),
            screencast: Self.source(id: "screen", kind: .screencast),
            omi: Self.source(id: "omi", kind: .omi),
            watch: nil
        )

        XCTAssertEqual(rows.map(\.route), [.audio, .location, .screencast, .omi])
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

    func testPrimaryRowsKeepWatchOrderWhenPresent() {
        let rows = SourcesViewRowBuilder.primaryRows(
            audio: Self.source(id: "audio", kind: .observer),
            location: Self.source(id: "location", kind: .location),
            screencast: Self.source(id: "screen", kind: .screencast),
            omi: Self.source(id: "omi", kind: .omi),
            watch: Self.source(id: "watch", kind: .watch)
        )

        XCTAssertEqual(rows.map(\.route), [.audio, .location, .screencast, .omi, .watch])
    }

    func testSourcesViewDoesNotRestoreWatchRowAttentionThirdLine() throws {
        let text = try String(contentsOf: Self.sourcesViewURL(), encoding: .utf8)
        let watchSourceConstruction = try Self.section(
            in: text,
            from: "nonisolated func watchSourceModel(",
            to: "// watchSourceModel-end"
        )

        XCTAssertFalse(watchSourceConstruction.contains("detailSubtext:"))
    }
}

private extension SourcesViewRowBuilderTests {
    static func source(id: String, kind: SourceKind) -> Source {
        Source(
            id: id,
            displayName: id,
            kind: kind,
            group: .experiencingAlongsideYou,
            state: .off,
            isJournalPaired: true,
            activeSubtext: "on",
            attention: nil,
            pendingStatus: .nonePending
        )
    }

    static func sourcesViewURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Home/SourceModelBuilder.swift")
    }

    static func section(in text: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start))
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex))
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }
}
