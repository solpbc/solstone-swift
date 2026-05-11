// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest
import os

private final class TestPathSource: PathMonitoringSource, @unchecked Sendable {
    var handler: (@Sendable () -> Void)?
    var startCount = 0
    var stopCount = 0

    func start(onPathChange: @Sendable @escaping () -> Void) {
        startCount += 1
        handler = onPathChange
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func trigger() {
        handler?()
    }
}

nonisolated final class PathMonitorTests: XCTestCase {
    @MainActor
    func testPathChangeEventsCoalesce() async {
        let source = TestPathSource()
        let monitor = PathMonitor(source: source)
        let count = OSAllocatedUnfairLock(initialState: 0)

        monitor.start {
            count.withLock { $0 += 1 }
        }
        source.trigger()
        source.trigger()
        source.trigger()
        try? await Task.sleep(for: .milliseconds(260))

        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    @MainActor
    func testStartStopAreIdempotent() {
        let source = TestPathSource()
        let monitor = PathMonitor(source: source)

        monitor.start {}
        monitor.start {}
        monitor.stop()
        monitor.stop()

        XCTAssertEqual(source.startCount, 2)
        XCTAssertEqual(source.stopCount, 4)
    }
}
