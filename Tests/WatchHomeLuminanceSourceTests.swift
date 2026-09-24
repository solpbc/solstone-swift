// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

/// The bi-modal watch face follows `isLuminanceReduced` (founder, 2026-09-23).
nonisolated final class WatchHomeLuminanceSourceTests: XCTestCase {
    func testTheModeFollowsLuminanceReduced() {
        XCTAssertEqual(WatchFaceMode(luminanceReduced: false), .active)
        XCTAssertEqual(WatchFaceMode(luminanceReduced: true), .reduced)
    }

    func testActiveShowsContentOnInkAndNoSunArc() {
        let mode = WatchFaceMode(luminanceReduced: false)
        XCTAssertTrue(mode.showsContent)
        XCTAssertFalse(mode.showsSunArc)
        XCTAssertEqual(mode.groundHex, "#1A1A1A")
    }

    func testReducedShowsOnlyTheSunArcOverBlack() {
        let mode = WatchFaceMode(luminanceReduced: true)
        XCTAssertFalse(mode.showsContent)
        XCTAssertTrue(mode.showsSunArc)
        XCTAssertEqual(mode.groundHex, "#000000")
    }
}
