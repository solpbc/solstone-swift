// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchComplicationTimelineTests: XCTestCase {
    func testComplicationRefreshFloorIsThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_713_624_000)

        XCTAssertEqual(SolstoneWatchComplicationRefresh.reloadInterval, 30 * 60)
        XCTAssertEqual(
            SolstoneWatchComplicationRefresh.nextReloadDate(after: now),
            now.addingTimeInterval(30 * 60)
        )
    }

    /// 🔒 The refresh floor must outlast the audio-verification horizon.
    ///
    /// `watchComplicationTimelinePoints` can emit a second entry at
    /// `lastVerifiedAudioAt + 2 × segmentDuration` that degrades the card to unknown. The
    /// fallback policy fires after the last entry, so a floor shorter than that horizon would
    /// re-request the timeline before the degradation point and waste budget.
    func testRefreshFloorOutlastsTheAudioVerificationHorizon() {
        XCTAssertGreaterThan(
            SolstoneWatchComplicationRefresh.reloadInterval,
            WatchCaptureTiming.segmentDurationSeconds * 2
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
