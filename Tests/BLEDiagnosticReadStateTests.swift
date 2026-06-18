// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class BLEDiagnosticReadStateTests: XCTestCase {
    func testStringPlaceholdersAreDistinctAndNonEmpty() throws {
        let notRead = try XCTUnwrap(BLEReadState<String>.notRead.placeholderText)
        let unavailable = try XCTUnwrap(BLEReadState<String>.unavailable.placeholderText)

        XCTAssertFalse(notRead.isEmpty)
        XCTAssertFalse(unavailable.isEmpty)
        XCTAssertNotEqual(notRead, unavailable)
        XCTAssertNil(BLEReadState<String>.value("firmware").placeholderText)
    }

    func testIntegerPlaceholdersAreDistinctAndNonEmpty() throws {
        let notRead = try XCTUnwrap(BLEReadState<Int>.notRead.placeholderText)
        let unavailable = try XCTUnwrap(BLEReadState<Int>.unavailable.placeholderText)

        XCTAssertFalse(notRead.isEmpty)
        XCTAssertFalse(unavailable.isEmpty)
        XCTAssertNotEqual(notRead, unavailable)
        XCTAssertNil(BLEReadState<Int>.value(93).placeholderText)
    }
}
