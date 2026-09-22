// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

nonisolated final class WatchElapsedDurationTests: XCTestCase {
    func testDisplayStrings() {
        XCTAssertEqual(watchElapsedDisplay(seconds: -10), "0s")
        XCTAssertEqual(watchElapsedDisplay(seconds: 0), "0s")
        XCTAssertEqual(watchElapsedDisplay(seconds: 59), "59s")
        XCTAssertEqual(watchElapsedDisplay(seconds: 60), "1m")
        XCTAssertEqual(watchElapsedDisplay(seconds: 59 * 60), "59m")
        XCTAssertEqual(watchElapsedDisplay(seconds: 60 * 60), "1h 0m")
        XCTAssertEqual(watchElapsedDisplay(seconds: 60 * 60 + 25 * 60), "1h 25m")
        XCTAssertEqual(watchElapsedDisplay(seconds: 2 * 3600), "2h 0m")
        XCTAssertEqual(watchElapsedDisplay(seconds: 50 * 3600), "50h 0m")
    }

    func testSpokenStrings() {
        XCTAssertEqual(watchElapsedSpoken(seconds: -10), "0 seconds")
        XCTAssertEqual(watchElapsedSpoken(seconds: 0), "0 seconds")
        XCTAssertEqual(watchElapsedSpoken(seconds: 1), "1 second")
        XCTAssertEqual(watchElapsedSpoken(seconds: 59), "59 seconds")
        XCTAssertEqual(watchElapsedSpoken(seconds: 60), "1 minute")
        XCTAssertEqual(watchElapsedSpoken(seconds: 59 * 60), "59 minutes")
        XCTAssertEqual(watchElapsedSpoken(seconds: 60 * 60), "1 hour")
        XCTAssertEqual(watchElapsedSpoken(seconds: 60 * 60 + 25 * 60), "1 hour, 25 minutes")
        XCTAssertEqual(watchElapsedSpoken(seconds: 2 * 3600), "2 hours")
        XCTAssertEqual(watchElapsedSpoken(seconds: 50 * 3600), "50 hours")
    }

    func testColonFreeSweep() {
        for seconds in 0..<10_000 {
            let display = watchElapsedDisplay(seconds: seconds)
            let spoken = watchElapsedSpoken(seconds: seconds)
            XCTAssertFalse(display.contains(":"), "Display contains colon: \(display)")
            XCTAssertFalse(spoken.contains(":"), "Spoken contains colon: \(spoken)")
        }
    }

    func testScheduleNextFireCases() {
        let baseTime: TimeInterval = 1_700_000_000
        let sessionStart = Date(timeIntervalSince1970: baseTime)

        // Case 1: 59s active not reduced -> now + 1
        let now59 = sessionStart.addingTimeInterval(59)
        let fire59 = watchHomeElapsedNextFire(
            sessionStart: sessionStart,
            now: now59,
            sceneActive: true,
            luminanceReduced: false
        )
        XCTAssertEqual(fire59, now59.addingTimeInterval(1))

        // Case 2: 61s active -> start + 120
        let now61 = sessionStart.addingTimeInterval(61)
        let fire61 = watchHomeElapsedNextFire(
            sessionStart: sessionStart,
            now: now61,
            sceneActive: true,
            luminanceReduced: false
        )
        XCTAssertEqual(fire61, sessionStart.addingTimeInterval(120))

        // Case 3: 10s reduced -> start + 60
        let now10 = sessionStart.addingTimeInterval(10)
        let fire10 = watchHomeElapsedNextFire(
            sessionStart: sessionStart,
            now: now10,
            sceneActive: true,
            luminanceReduced: true
        )
        XCTAssertEqual(fire10, sessionStart.addingTimeInterval(60))

        // Case 4: 60s active -> start + 120
        let now60 = sessionStart.addingTimeInterval(60)
        let fire60 = watchHomeElapsedNextFire(
            sessionStart: sessionStart,
            now: now60,
            sceneActive: true,
            luminanceReduced: false
        )
        XCTAssertEqual(fire60, sessionStart.addingTimeInterval(120))

        // Case 5: -5s reduced -> equal to sessionStart (and strictly after now)
        let nowMinus5 = sessionStart.addingTimeInterval(-5)
        let fireMinus5 = watchHomeElapsedNextFire(
            sessionStart: sessionStart,
            now: nowMinus5,
            sceneActive: true,
            luminanceReduced: true
        )
        XCTAssertEqual(fireMinus5, sessionStart)
        XCTAssertGreaterThan(fireMinus5, nowMinus5)
    }
}
