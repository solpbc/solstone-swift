// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class BrainStatusMonitorTests: XCTestCase {
    @MainActor private var monitor = BrainStatusMonitor()

    @MainActor
    func testInitialStatusIsUnavailable() {
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    @MainActor
    func testUpdateRefreshing() {
        self.monitor.update(from: #"{"status": "refreshing"}"#)
        XCTAssertEqual(self.monitor.status, .refreshing)
    }

    @MainActor
    func testUpdateReady() {
        self.monitor.update(from: #"{"status": "ready"}"#)
        XCTAssertEqual(self.monitor.status, .ready)
    }

    @MainActor
    func testUpdateIdle() {
        self.monitor.update(from: #"{"status": "idle"}"#)
        XCTAssertEqual(self.monitor.status, .ready)
    }

    @MainActor
    func testUpdateAnswering() {
        self.monitor.update(from: #"{"status": "answering"}"#)
        XCTAssertEqual(self.monitor.status, .answering)
    }

    @MainActor
    func testUpdateUnknownStatus() {
        self.monitor.update(from: #"{"status": "something_new"}"#)
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    @MainActor
    func testUpdateInvalidJSON() {
        self.monitor.update(from: "not json at all")
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    @MainActor
    func testUpdateEmptyString() {
        self.monitor.update(from: "")
        XCTAssertEqual(self.monitor.status, .unavailable)
    }

    @MainActor
    func testReset() {
        self.monitor.update(from: #"{"status": "refreshing"}"#)
        XCTAssertEqual(self.monitor.status, .refreshing)
        self.monitor.reset()
        XCTAssertEqual(self.monitor.status, .unavailable)
    }
}
