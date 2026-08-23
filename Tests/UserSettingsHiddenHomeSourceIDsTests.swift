// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class UserSettingsHiddenHomeSourceIDsTests: XCTestCase {
    func testDefaultEmptyMeansEverythingVisible() {
        XCTAssertEqual(UserSettings.decodeHiddenHomeSourceIDs(nil), [])
        XCTAssertEqual(UserSettings.decodeHiddenHomeSourceIDs(Data()), [])
    }

    func testRoundTripAndMalformedFailsOpen() {
        let encoded = UserSettings.encodeHiddenHomeSourceIDs(["omi", "audio"])
        XCTAssertEqual(UserSettings.decodeHiddenHomeSourceIDs(encoded), ["audio", "omi"])
        XCTAssertEqual(UserSettings.decodeHiddenHomeSourceIDs(Data("not-json".utf8)), [])
    }

    func testToggleOffRemovesFromVisibleSet() {
        var hidden = Set<String>()
        hidden.insert("audio")
        let data = UserSettings.encodeHiddenHomeSourceIDs(hidden)
        let decoded = UserSettings.decodeHiddenHomeSourceIDs(data)
        XCTAssertTrue(decoded.contains("audio"))
        XCTAssertFalse(decoded.contains("location"))
    }

    func testPersistedHiddenIdDropsTileFromHomeFilter() throws {
        let suiteName = "hiddenHomeSourceIDs.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        UserSettings.setHiddenHomeSourceIDs(["audio"], in: suite)
        let stored = UserSettings.hiddenHomeSourceIDs(in: suite)
        XCTAssertEqual(stored, ["audio"])
        XCTAssertFalse(isHomeSourceVisible(id: "audio", hiddenIDs: stored))
        XCTAssertTrue(isHomeSourceVisible(id: "location", hiddenIDs: stored))
    }
}
