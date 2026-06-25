// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class WatchStatusContextTests: XCTestCase {
    func testApplicationContextRoundTripsThroughJSONData() throws {
        let context = WatchStatusContext(
            phase: .observing,
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_000),
            asOf: Date(timeIntervalSince1970: 1_015),
            seq: 7
        )

        let applicationContext = context.applicationContext()

        XCTAssertTrue(applicationContext[WatchStatusContext.applicationContextKey] is Data)
        XCTAssertEqual(WatchStatusContext(applicationContext: applicationContext), context)
    }

    func testMissingContextReturnsNil() {
        XCTAssertNil(WatchStatusContext(applicationContext: [:]))
    }

    func testNonDataContextReturnsNil() {
        XCTAssertNil(WatchStatusContext(applicationContext: [
            WatchStatusContext.applicationContextKey: "not data",
        ]))
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(WatchStatusContext(applicationContext: [
            WatchStatusContext.applicationContextKey: Data("garbage".utf8),
        ]))
    }
}
