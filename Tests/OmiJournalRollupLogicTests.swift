// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiJournalRollupLogicTests: XCTestCase {
    func testDurationTextBoundaries() {
        XCTAssertEqual(OmiJournalRollupLogic.durationText(seconds: 30), "<1m")
        XCTAssertEqual(OmiJournalRollupLogic.durationText(seconds: 47 * 60), "47m")
        XCTAssertEqual(OmiJournalRollupLogic.durationText(seconds: 3_600), "1h")
        XCTAssertEqual(OmiJournalRollupLogic.durationText(seconds: 7_200), "2h")
        XCTAssertEqual(OmiJournalRollupLogic.durationText(seconds: 3_660), "1h 1m")
        XCTAssertEqual(OmiJournalRollupLogic.durationText(seconds: 14_100), "3h 55m")
    }

    func testRollupTextZeroSingularAndPlural() {
        let now = Self.date("2026-06-23T12:00:00Z")
        let day = OmiSegmentWriter.dayString(for: now)

        XCTAssertEqual(OmiJournalRollupLogic.rowLabel, "your journal")
        XCTAssertEqual(OmiJournalRollupLogic.rollupText(tally: [:], now: now), "nothing yet today")
        XCTAssertEqual(
            OmiJournalRollupLogic.rollupText(
                tally: [
                    day: OmiJournalDayTally(segmentCount: 1, totalSeconds: 47 * 60, seenIdentities: ["one"])
                ],
                now: now
            ),
            "1 segment · 47m today"
        )
        XCTAssertEqual(
            OmiJournalRollupLogic.rollupText(
                tally: [
                    day: OmiJournalDayTally(segmentCount: 2, totalSeconds: 3_660, seenIdentities: ["one", "two"])
                ],
                now: now
            ),
            "2 segments · 1h 1m today"
        )
    }

    func testRollupTextUsesTodayKeyAndIgnoresYesterdayEntry() {
        let now = Self.date("2026-06-23T12:00:00Z")
        let today = OmiSegmentWriter.dayString(for: now)
        let yesterday = OmiSegmentWriter.dayString(for: now.addingTimeInterval(-86_400))
        let tally: OmiJournalTallyPayload = [
            yesterday: OmiJournalDayTally(segmentCount: 9, totalSeconds: 14_100, seenIdentities: ["old"]),
            today: OmiJournalDayTally(segmentCount: 1, totalSeconds: 60, seenIdentities: ["new"]),
        ]

        XCTAssertEqual(
            OmiJournalRollupLogic.rollupText(tally: tally, now: now),
            "1 segment · 1m today"
        )
    }

    private static func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
