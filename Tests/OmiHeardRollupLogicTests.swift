// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiHeardRollupLogicTests: XCTestCase {
    func testDurationTextBoundaries() {
        XCTAssertEqual(OmiHeardRollupLogic.durationText(seconds: 30), "<1m")
        XCTAssertEqual(OmiHeardRollupLogic.durationText(seconds: 47 * 60), "47m")
        XCTAssertEqual(OmiHeardRollupLogic.durationText(seconds: 3_600), "1h")
        XCTAssertEqual(OmiHeardRollupLogic.durationText(seconds: 7_200), "2h")
        XCTAssertEqual(OmiHeardRollupLogic.durationText(seconds: 3_660), "1h 1m")
        XCTAssertEqual(OmiHeardRollupLogic.durationText(seconds: 14_100), "3h 55m")
    }

    func testHeardTextZeroAndNonZero() {
        let now = Self.date("2026-06-23T12:00:00Z")
        let day = ObserverSegmentNaming.dayString(for: now)

        XCTAssertEqual(OmiHeardRollupLogic.rowLabel, "heard today")
        XCTAssertEqual(OmiHeardRollupLogic.heardText(tally: [:], now: now), "nothing yet")
        XCTAssertEqual(
            OmiHeardRollupLogic.heardText(
                tally: [
                    day: OmiHeardDayTally(totalSeconds: 0, seenIdentities: ["zero"])
                ],
                now: now
            ),
            "nothing yet"
        )
        XCTAssertEqual(
            OmiHeardRollupLogic.heardText(
                tally: [
                    day: OmiHeardDayTally(totalSeconds: 47 * 60, seenIdentities: ["one"])
                ],
                now: now
            ),
            "47m"
        )
    }

    func testHeardTextUsesTodayKeyAndIgnoresYesterdayEntry() {
        let now = Self.date("2026-06-23T12:00:00Z")
        let today = ObserverSegmentNaming.dayString(for: now)
        let yesterday = ObserverSegmentNaming.dayString(for: now.addingTimeInterval(-86_400))
        let tally: OmiHeardTallyPayload = [
            yesterday: OmiHeardDayTally(totalSeconds: 14_100, seenIdentities: ["old"]),
            today: OmiHeardDayTally(totalSeconds: 60, seenIdentities: ["new"]),
        ]

        XCTAssertEqual(
            OmiHeardRollupLogic.heardText(tally: tally, now: now),
            "1m"
        )
    }

    private static func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
