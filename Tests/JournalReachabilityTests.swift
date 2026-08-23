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

    func testStatusDegradedMapsFiveNonConnectedCases() {
        for status in [
            ConnectionSyncStatus.offline,
            .connecting,
            .waitingForHome,
            .reconnecting,
            .unreachable,
        ] {
            let region = statusPaneRegion(status)
            XCTAssertEqual(region.id, "shell.pane.status.degraded", status.statusLine)
            XCTAssertEqual(region.value, status.statusLine)
            XCTAssertNotEqual(region.value, "0")
            XCTAssertFalse(region.value.isEmpty)
        }
    }

    func testStatusConnectedTwinMapsThreeConnectedCases() {
        for status in [
            ConnectionSyncStatus.connectedIdle,
            .connectedWaiting,
            .connectedTransferring,
        ] {
            let region = statusPaneRegion(status)
            XCTAssertEqual(region.id, "shell.pane.status.connected", status.statusLine)
            XCTAssertEqual(region.value, status.statusLine)
            XCTAssertNotEqual(region.value, "0")
            XCTAssertFalse(region.value.isEmpty)
        }
    }
}
