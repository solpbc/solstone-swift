// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest
import os

private final class TestPathSource: PathMonitoringSource, @unchecked Sendable {
    var handler: (@Sendable (NetworkPathStatus) -> Void)?
    var startCount = 0
    var stopCount = 0

    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        startCount += 1
        handler = onPathChange
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func trigger(_ status: NetworkPathStatus = .satisfiedWiFi) {
        handler?(status)
    }
}

nonisolated final class PathMonitorTests: XCTestCase {
    @MainActor
    func testPathChangeEventsCoalesce() async {
        let source = TestPathSource()
        let monitor = PathMonitor(source: source)
        let count = OSAllocatedUnfairLock(initialState: 0)

        monitor.start { _ in
            count.withLock { $0 += 1 }
        }
        source.trigger()
        source.trigger()
        source.trigger()
        try? await Task.sleep(for: .milliseconds(260))

        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    @MainActor
    func testPathChangeEnqueuedBeforeStopDoesNotFireAfterStop() async {
        let source = TestPathSource()
        let monitor = PathMonitor(source: source)
        let count = OSAllocatedUnfairLock(initialState: 0)

        monitor.start { _ in
            count.withLock { $0 += 1 }
        }
        source.trigger()
        monitor.stop()
        try? await Task.sleep(for: .milliseconds(260))

        XCTAssertEqual(count.withLock { $0 }, 0)
    }

    @MainActor
    func testPathChangeDeliversLatestFacts() async {
        let source = TestPathSource()
        let monitor = PathMonitor(source: source)
        let latest = OSAllocatedUnfairLock<NetworkPathStatus?>(initialState: nil)

        monitor.start { status in
            latest.withLock { $0 = status }
        }
        source.trigger(.satisfiedWiFi)
        source.trigger(NetworkPathStatus(
            isSatisfied: false,
            isWiFi: false,
            isCellular: true,
            isExpensive: true,
            isConstrained: true
        ))
        try? await Task.sleep(for: .milliseconds(260))

        XCTAssertEqual(latest.withLock { $0 }, NetworkPathStatus(
            isSatisfied: false,
            isWiFi: false,
            isCellular: true,
            isExpensive: true,
            isConstrained: true
        ))
    }

    @MainActor
    func testStartStopAreIdempotent() {
        let source = TestPathSource()
        let monitor = PathMonitor(source: source)

        monitor.start { _ in }
        monitor.start { _ in }
        monitor.stop()
        monitor.stop()

        XCTAssertEqual(source.startCount, 2)
        XCTAssertEqual(source.stopCount, 4)
    }
}

private extension NetworkPathStatus {
    static let satisfiedWiFi = NetworkPathStatus(
        isSatisfied: true,
        isWiFi: true,
        isCellular: false,
        isExpensive: false,
        isConstrained: false
    )
}
