// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

final class BrainStatusMonitorTests: XCTestCase {
    private var monitor = BrainStatusMonitor()

    override func setUp() {
        self.monitor = BrainStatusMonitor()
    }

    func testInitialStatusIsUnavailable() {
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    func testUpdateRefreshing() {
        self.monitor.update(from: #"{"status": "refreshing"}"#)
        XCTAssertEqual(self.monitor.status, .refreshing)
    }

    func testUpdateReady() {
        self.monitor.update(from: #"{"status": "ready"}"#)
        XCTAssertEqual(self.monitor.status, .idle)
    }

    func testUpdateIdle() {
        self.monitor.update(from: #"{"status": "idle"}"#)
        XCTAssertEqual(self.monitor.status, .idle)
    }

    func testUpdateAnswering() {
        self.monitor.update(from: #"{"status": "answering"}"#)
        XCTAssertEqual(self.monitor.status, .answering)
    }

    func testUpdateUnknownStatus() {
        self.monitor.update(from: #"{"status": "something_new"}"#)
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    func testUpdateInvalidJSON() {
        self.monitor.update(from: "not json at all")
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    func testUpdateEmptyString() {
        self.monitor.update(from: "")
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    func testReset() {
        self.monitor.update(from: #"{"status": "refreshing"}"#)
        XCTAssertEqual(self.monitor.status, .refreshing)
        self.monitor.reset()
        XCTAssertEqual(self.monitor.status, .unavailable)
    }
}
