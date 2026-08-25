// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchComplicationTimelineTests: XCTestCase {
    func testSmartStackReloadIntervalIsThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_713_624_000)

        XCTAssertEqual(SolstoneWatchStatusSmartStack.reloadInterval, 30 * 60)
        XCTAssertEqual(
            SolstoneWatchStatusSmartStack.nextReloadDate(after: now),
            now.addingTimeInterval(30 * 60)
        )
    }

    func testTimelineHelperReturnsLiveEntryBeforeAudioVerificationHorizon() {
        let verifiedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let now = verifiedAt.addingTimeInterval(120)
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: verifiedAt,
                lastVerifiedAudioAt: verifiedAt
            ),
            isReachable: true
        )

        let points = watchComplicationTimelinePoints(snapshot: snapshot, now: now)

        XCTAssertEqual(points.first, WatchComplicationTimelinePoint(date: now, snapshot: snapshot))
        XCTAssertEqual(
            points.last?.date,
            verifiedAt.addingTimeInterval(WatchCaptureTiming.segmentDurationSeconds * 2)
        )
        XCTAssertNil(points.last?.snapshot)
    }

    func testTimelineHelperReturnsUnknownWhenAudioVerificationIsMissing() {
        let now = Date(timeIntervalSince1970: 1_713_624_100)
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: Date(timeIntervalSince1970: 1_713_624_000)
            ),
            isReachable: true
        )

        XCTAssertEqual(watchComplicationTimelinePoints(snapshot: snapshot, now: now), [
            WatchComplicationTimelinePoint(date: now, snapshot: nil),
        ])
    }
}
