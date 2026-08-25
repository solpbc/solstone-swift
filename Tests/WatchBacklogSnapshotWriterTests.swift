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
}

// Mirrors SolstoneLiveActivityWidget/WatchBacklogSnapshot.swift; keep it in
// sync because the widget source is intentionally not compiled into this iOS
// test target.
private struct LiveWidgetWireMirror: Codable {
    let knownCount: Int
    let watchTotalIsUnknown: Bool
    let watchStatusAsOf: Date?
}
