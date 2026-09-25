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

    /// 🔒 A healthy capture never shows the card as unknown.
    ///
    /// Drives the real reload guard and the real timeline helper up to the refresh floor of a
    /// capture: audio is verified at every segment boundary, the app reloads only when
    /// `requiresTimelineReload` says so. At every tick before the floor fires, the
    /// entry in effect must be the live snapshot. A guard that skips verification-only changes
    /// leaves the start timeline in place, and its unknown entry takes effect two segments in.
    func testHealthyCaptureNeverRendersUnknownBetweenReloads() {
        let segment = WatchCaptureTiming.segmentDurationSeconds
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let end = startedAt.addingTimeInterval(SolstoneWatchComplicationRefresh.reloadInterval)
        func snapshot(verifiedAt: Date) -> WatchComplicationSnapshot {
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(
                    status: .active,
                    queuedCount: 0,
                    isSessionRunning: true,
                    sessionStartedAt: startedAt,
                    lastVerifiedAudioAt: verifiedAt
                ),
                isReachable: true
            )
        }

        var published = snapshot(verifiedAt: startedAt)
        var timeline = watchComplicationTimelinePoints(snapshot: published, now: startedAt)
        var nextVerification = startedAt.addingTimeInterval(segment)
        var tick = startedAt
        while tick <= end {
            if tick >= nextVerification {
                let verified = snapshot(verifiedAt: nextVerification)
                if verified.requiresTimelineReload(comparedTo: published) {
                    timeline = watchComplicationTimelinePoints(snapshot: verified, now: tick)
                }
                published = verified
                nextVerification = nextVerification.addingTimeInterval(segment)
            }
            let inEffect = timeline.last { $0.date <= tick }
            XCTAssertNotNil(
                inEffect?.snapshot,
                "card reads unknown \(Int(tick.timeIntervalSince(startedAt)))s into a healthy capture"
            )
            tick = tick.addingTimeInterval(30)
        }
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
