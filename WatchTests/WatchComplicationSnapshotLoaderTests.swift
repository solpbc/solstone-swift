// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchComplicationSnapshotLoaderTests: XCTestCase {
    func testSnapshotLoaderDecodesLegacyPayloadWithoutMark() throws {
        let containerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(containerURL) }
        let json = """
        {
          "stateWord": "legacy",
          "role": {"calm":{}},
          "showsElapsed": false
        }
        """
        try Self.write(json, to: containerURL)

        let snapshot = try XCTUnwrap(loadWatchComplicationSnapshot(from: containerURL))

        XCTAssertEqual(snapshot.mark, .cloud)
        XCTAssertEqual(snapshot.role, .calm)
    }

    func testSnapshotLoaderReturnsDecodedRoundTripSnapshot() throws {
        let containerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(containerURL) }
        let snapshot = WatchComplicationSnapshot(
            stateWord: SourceVocabulary.watchHeadlineListening,
            role: .live,
            mark: .sun,
            showsElapsed: true,
            sessionStartedAt: Date(timeIntervalSinceReferenceDate: 100),
            handoffLine: SourceVocabulary.watchSendingCount(2),
            handoffSubtext: nil,
            handoffRole: .flight,
            trustLine: SourceVocabulary.trustLineConfigured
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: Self.snapshotURL(in: containerURL), options: .atomic)

        XCTAssertEqual(loadWatchComplicationSnapshot(from: containerURL), snapshot)
    }

    func testSnapshotLoaderReturnsNilForMalformedJSON() throws {
        let containerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(containerURL) }
        try Self.write("{", to: containerURL)

        XCTAssertNil(loadWatchComplicationSnapshot(from: containerURL))
    }

    func testSnapshotLoaderReturnsNilForAbsentAndUnreadableInputs() throws {
        let absentContainerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(absentContainerURL) }

        XCTAssertNil(loadWatchComplicationSnapshot(from: absentContainerURL))

        let unreadableContainerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(unreadableContainerURL) }
        try FileManager.default.createDirectory(
            at: Self.snapshotURL(in: unreadableContainerURL),
            withIntermediateDirectories: false
        )

        XCTAssertNil(loadWatchComplicationSnapshot(from: unreadableContainerURL))
    }
}

private extension WatchComplicationSnapshotLoaderTests {
    static func makeContainerURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-watch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeContainerURL(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func snapshotURL(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent(WatchComplicationSnapshot.fileName, isDirectory: false)
    }

    static func write(_ string: String, to containerURL: URL) throws {
        let data = try XCTUnwrap(string.data(using: .utf8))
        try data.write(to: Self.snapshotURL(in: containerURL), options: .atomic)
    }
}
