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

        XCTAssertEqual(snapshot.mark, .paused)
        XCTAssertEqual(snapshot.role, .calm)
    }

    func testSnapshotLoaderReturnsDecodedRoundTripSnapshot() throws {
        let containerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(containerURL) }
        let snapshot = WatchComplicationSnapshot(
            stateWord: SourceVocabulary.watchHeadlineListening,
            role: .live,
            mark: .healthy,
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

    func testSnapshotLoaderDecodesPresentCloudMarkAsPaused() throws {
        let containerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(containerURL) }
        let json = """
        {
          "stateWord": "legacy",
          "role": {"calm":{}},
          "showsElapsed": false,
          "mark": "cloud"
        }
        """
        try Self.write(json, to: containerURL)

        let snapshot = try XCTUnwrap(loadWatchComplicationSnapshot(from: containerURL))

        XCTAssertEqual(snapshot.mark, .paused)
        XCTAssertNotEqual(snapshot.mark, .connecting)
    }

    func testSnapshotLoaderDecodesPresentSunAndBangMarks() throws {
        let containerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(containerURL) }

        try Self.write(
            """
            {
              "stateWord": "legacy",
              "role": {"live":{}},
              "showsElapsed": false,
              "mark": "sun"
            }
            """,
            to: containerURL
        )
        let sunSnapshot = try XCTUnwrap(loadWatchComplicationSnapshot(from: containerURL))
        XCTAssertEqual(sunSnapshot.mark, .healthy)

        try Self.write(
            """
            {
              "stateWord": "legacy",
              "role": {"alert":{}},
              "showsElapsed": false,
              "mark": "bang"
            }
            """,
            to: containerURL
        )
        let bangSnapshot = try XCTUnwrap(loadWatchComplicationSnapshot(from: containerURL))
        XCTAssertEqual(bangSnapshot.mark, .attention)
    }

    func testSnapshotLoaderDecodesMissingMarkFromLiveAndAlertRoles() throws {
        let liveContainerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(liveContainerURL) }
        try Self.write(
            """
            {
              "stateWord": "legacy",
              "role": {"live":{}},
              "showsElapsed": false
            }
            """,
            to: liveContainerURL
        )
        let liveSnapshot = try XCTUnwrap(loadWatchComplicationSnapshot(from: liveContainerURL))
        XCTAssertEqual(liveSnapshot.mark, .healthy)

        let alertContainerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(alertContainerURL) }
        try Self.write(
            """
            {
              "stateWord": "legacy",
              "role": {"alert":{}},
              "showsElapsed": false
            }
            """,
            to: alertContainerURL
        )
        let alertSnapshot = try XCTUnwrap(loadWatchComplicationSnapshot(from: alertContainerURL))
        XCTAssertEqual(alertSnapshot.mark, .attention)
    }

    func testSnapshotLoaderRoundTripsEnrollingAsConnecting() throws {
        let containerURL = try Self.makeContainerURL()
        defer { Self.removeContainerURL(containerURL) }
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .enrolling, queuedCount: 0),
            isReachable: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: Self.snapshotURL(in: containerURL), options: .atomic)

        let loaded = try XCTUnwrap(loadWatchComplicationSnapshot(from: containerURL))
        XCTAssertEqual(loaded.mark, .connecting)
        XCTAssertNotEqual(loaded.mark, .paused)
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
