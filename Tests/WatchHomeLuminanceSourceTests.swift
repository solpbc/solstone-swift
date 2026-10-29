// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

/// The watch face follows `isLuminanceReduced`: the sun arc is always drawn, and the controls
/// and details show only while the wrist is up.
nonisolated final class WatchHomeLuminanceSourceTests: XCTestCase {
    func testTheModeFollowsLuminanceReduced() {
        XCTAssertEqual(WatchFaceMode(luminanceReduced: false), .active)
        XCTAssertEqual(WatchFaceMode(luminanceReduced: true), .reduced)
    }

    func testWristUpShowsContentOnTheSunArc() {
        let mode = WatchFaceMode(luminanceReduced: false)
        XCTAssertTrue(mode.showsContent)
        XCTAssertFalse(mode.blackGround)
    }

    func testWristDownShowsOnlyTheSunArcOverBlack() {
        let mode = WatchFaceMode(luminanceReduced: true)
        XCTAssertFalse(mode.showsContent)
        XCTAssertTrue(mode.blackGround)
    }
}
