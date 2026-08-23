// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class DayHomeGreetingTests: XCTestCase {
    func testGreetingBucketsByHour() {
        XCTAssertEqual(greeting(forHour: 9), "good morning")
        XCTAssertEqual(greeting(forHour: 11), "good morning")
        XCTAssertEqual(greeting(forHour: 12), "good afternoon")
        XCTAssertEqual(greeting(forHour: 14), "good afternoon")
        XCTAssertEqual(greeting(forHour: 16), "good afternoon")
        XCTAssertEqual(greeting(forHour: 17), "good evening")
        XCTAssertEqual(greeting(forHour: 20), "good evening")
        XCTAssertEqual(greeting(forHour: 2), "good evening")
        XCTAssertEqual(greeting(forHour: 0), "good evening")
        XCTAssertEqual(greeting(forHour: 23), "good evening")
    }

    func testDayHomeJournalStateFromPairingAndSyncStatus() {
        XCTAssertEqual(dayHomeJournalState(isPaired: false, status: .connectedIdle), .noJournal)
        XCTAssertEqual(dayHomeJournalState(isPaired: false, status: .offline), .noJournal)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .connectedIdle), .linkedOnline)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .connectedWaiting), .linkedOnline)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .connectedTransferring), .linkedOnline)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .offline), .linkedOffline)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .connecting), .linkedOffline)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .waitingForHome), .linkedOffline)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .reconnecting), .linkedOffline)
        XCTAssertEqual(dayHomeJournalState(isPaired: true, status: .unreachable), .linkedOffline)
    }
}
