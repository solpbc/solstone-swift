// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

/// A `Double` whose rounding is not an `Int` (NaN, an infinity, or a finite value past `Int`'s
/// range, which a stored manifest can decode) never stops the app where it becomes a whole
/// number. A segment name falls back to the 1-second form its writers already use as a floor.
nonisolated final class UnusableDurationTests: XCTestCase {
    private static let unusable: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, 9.3e18]

    func testASegmentNameForAnUnusableDurationEndsInOneSecond() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-09T14:58:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        for duration in Self.unusable {
            XCTAssertEqual(SegmentWireTimeFormatter.durationSuffix(seconds: duration), 1, "\(duration)")
            XCTAssertEqual(ChunkSidecar.segmentString(for: start, durationSeconds: duration, timeZone: zone), "085800_1", "\(duration)")
            XCTAssertEqual(
                WatchCaptureStoragePaths.segmentString(for: start, durationSeconds: duration, timeZone: zone),
                "085800_1",
                "\(duration)"
            )
        }
        XCTAssertEqual(SegmentWireTimeFormatter.durationSuffix(seconds: 0.4), 1)
        XCTAssertEqual(SegmentWireTimeFormatter.durationSuffix(seconds: 47.6), 48)
        XCTAssertEqual(SegmentWireTimeFormatter.durationSuffix(seconds: 300), 300)
    }

    func testAnUnusableObservationTimeLeavesOutLastSeen() {
        let now = Date(timeIntervalSince1970: 1_780_480_800)
        for observedAt in Self.unusable {
            XCTAssertEqual(
                AboutBlock.line(name: "journal", version: "2.0.38", isCurrent: false, observedAt: observedAt, now: now),
                "journal 2.0.38",
                "\(observedAt)"
            )
        }
    }

    func testAnUnusableColourComponentClampsToAByte() {
        XCTAssertEqual(SunArcOKLab.hex(fromRGB: SunArcOKLab.RGB(r: .nan, g: .infinity, b: -.infinity)), "#00FF00")
        XCTAssertEqual(SunArcOKLab.hex(fromRGB: SunArcOKLab.RGB(r: 1e300, g: -1e300, b: 0.5)), "#FF0080")
    }

    func testAnUnusableDiagnosticsDurationReadsAsZeroSeconds() {
        for seconds in Self.unusable {
            XCTAssertEqual(WatchPipelineReducer.secondsText(seconds), "0s", "\(seconds)")
        }
        XCTAssertEqual(WatchPipelineReducer.secondsText(12.4), "12s")
    }
}
