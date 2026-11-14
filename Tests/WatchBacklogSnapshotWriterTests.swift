// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class WatchBacklogSnapshotWriterTests: XCTestCase {
    func testWriterBytesDecodeWithLiveWidgetWireMirror() throws {
        let asOf = Date(timeIntervalSince1970: 1_000)
        let stalePayload = WatchBacklogSnapshotPayload(
            backlog: .partiallyUnknown(known: 4, asOf: asOf),
            watchStatusAsOf: asOf
        )
        let staleData = try WatchBacklogSnapshotWriter.makeEncoder().encode(stalePayload)
        let staleMirror = try JSONDecoder().decode(LiveWidgetWireMirror.self, from: staleData)

        XCTAssertEqual(staleMirror.knownCount, 4)
        XCTAssertTrue(staleMirror.watchTotalIsUnknown)
        XCTAssertEqual(staleMirror.watchStatusAsOf, asOf)

        let unknownPayload = WatchBacklogSnapshotPayload(
            backlog: .partiallyUnknown(known: 0, asOf: nil),
            watchStatusAsOf: nil
        )
        let unknownData = try WatchBacklogSnapshotWriter.makeEncoder().encode(unknownPayload)
        let unknownMirror = try JSONDecoder().decode(LiveWidgetWireMirror.self, from: unknownData)

        XCTAssertEqual(unknownMirror.knownCount, 0)
        XCTAssertTrue(unknownMirror.watchTotalIsUnknown)
        XCTAssertNil(unknownMirror.watchStatusAsOf)
    }

    /// The home screen asks for this write on every change to what it shows. An
    /// unchanged snapshot must not rewrite the file.
    @MainActor func testAnUnchangedSnapshotIsNotRewritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = WatchBacklogSnapshotWriter(rootURLProvider: { root })
        let url = root.appendingPathComponent(WatchBacklogSnapshotPayload.fileName)
        func identity() throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
        }
        XCTAssertTrue(writer.write(backlog: .known(3), watchStatusAsOf: nil))
        let first = try identity()
        XCTAssertTrue(writer.write(backlog: .known(3), watchStatusAsOf: nil))
        XCTAssertEqual(try identity(), first)
        XCTAssertTrue(writer.write(backlog: .known(4), watchStatusAsOf: nil))
        XCTAssertNotEqual(try identity(), first)
        let written = try JSONDecoder().decode(LiveWidgetWireMirror.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.knownCount, 4)
    }
}

// Mirrors SolstoneLiveActivityWidget/WatchBacklogSnapshot.swift; keep it in
// sync because the widget source is intentionally not compiled into this iOS
// test target.
private struct LiveWidgetWireMirror: Codable {
    let knownCount: Int
    let watchTotalIsUnknown: Bool
    let watchStatusAsOf: Date?
}
