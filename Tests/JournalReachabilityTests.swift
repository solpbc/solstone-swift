// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class JournalReachabilityTests: XCTestCase {
    func testJournalReachabilityMapsAllConnectionSyncStatuses() {
        XCTAssertFalse(isJournalReachable(.offline))
        XCTAssertFalse(isJournalReachable(.connecting))
        XCTAssertFalse(isJournalReachable(.waitingForHome))
        XCTAssertFalse(isJournalReachable(.reconnecting))
        XCTAssertFalse(isJournalReachable(.unreachable))
        XCTAssertTrue(isJournalReachable(.connectedIdle))
        XCTAssertTrue(isJournalReachable(.connectedWaiting))
        XCTAssertTrue(isJournalReachable(.connectedTransferring))
    }
}
