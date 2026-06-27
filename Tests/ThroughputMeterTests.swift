// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ThroughputMeterTests: XCTestCase {
    @MainActor
    func testBytesPerSecondUsesFixedWindowAndExpiresOldEntries() {
        let base = Date(timeIntervalSince1970: 1_713_624_000)
        let meter = ThroughputMeter()

        XCTAssertEqual(meter.bytesPerSecond(now: base), 0)

        meter.record(bytes: 100_000, at: base)
        meter.record(bytes: 100_000, at: base.addingTimeInterval(1))
        meter.record(bytes: 100_000, at: base.addingTimeInterval(2))

        XCTAssertEqual(
            meter.bytesPerSecond(now: base.addingTimeInterval(3)),
            20_000,
            accuracy: 0.001
        )
        XCTAssertEqual(meter.bytesPerSecond(now: base.addingTimeInterval(30)), 0)
    }
}
