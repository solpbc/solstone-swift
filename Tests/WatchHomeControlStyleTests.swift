// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

nonisolated final class WatchHomeControlStyleTests: XCTestCase {
    func testMinHeightConstant() {
        XCTAssertEqual(WatchHomeControlStyle.minHeight, 44)
    }

    func testRunningNotReduced() {
        let style = watchHomeControlStyle(isRunning: true, luminanceReduced: false)
        XCTAssertEqual(style.label, "stop")
        XCTAssertEqual(style.fillHex, "#3A3632")
        XCTAssertEqual(style.labelHex, WatchHomePalette.cream)
        XCTAssertEqual(style.labelAlpha, 1.0)
        XCTAssertNil(style.strokeHex)
        XCTAssertEqual(style.strokeAlpha, 0.0)
        XCTAssertEqual(style.strokeLineWidth, 0.0)
    }

    func testNotRunningNotReduced() {
        let style = watchHomeControlStyle(isRunning: false, luminanceReduced: false)
        XCTAssertEqual(style.label, "start")
        XCTAssertEqual(style.fillHex, SunArc.orangeHex)
        XCTAssertEqual(style.labelHex, SunArc.inkHex)
        XCTAssertEqual(style.labelAlpha, 1.0)
        XCTAssertNil(style.strokeHex)
        XCTAssertEqual(style.strokeAlpha, 0.0)
        XCTAssertEqual(style.strokeLineWidth, 0.0)
    }

    func testRunningReduced() {
        let style = watchHomeControlStyle(isRunning: true, luminanceReduced: true)
        XCTAssertEqual(style.label, "stop")
        XCTAssertNil(style.fillHex)
        XCTAssertEqual(style.labelHex, WatchHomePalette.cream)
        XCTAssertEqual(style.labelAlpha, WatchHomePalette.reducedContentOpacity)
        XCTAssertEqual(style.strokeHex, SunArc.orangeHex)
        XCTAssertEqual(style.strokeAlpha, WatchHomePalette.reducedContentOpacity)
        XCTAssertEqual(style.strokeLineWidth, 3.0)
    }

    func testNotRunningReduced() {
        let style = watchHomeControlStyle(isRunning: false, luminanceReduced: true)
        XCTAssertEqual(style.label, "start")
        XCTAssertNil(style.fillHex)
        XCTAssertEqual(style.labelHex, SunArc.orangeHex)
        XCTAssertEqual(style.labelAlpha, WatchHomePalette.reducedContentOpacity)
        XCTAssertEqual(style.strokeHex, SunArc.orangeHex)
        XCTAssertEqual(style.strokeAlpha, WatchHomePalette.reducedContentOpacity)
        XCTAssertEqual(style.strokeLineWidth, 3.0)
    }

    func testAnUnfilledControlNeverDrawsAnInkLabel() {
        for isRunning in [false, true] {
            let style = watchHomeControlStyle(isRunning: isRunning, luminanceReduced: true)
            XCTAssertNil(style.fillHex)
            XCTAssertNotEqual(style.labelHex, SunArc.inkHex, "an ink label on the black wrist-down ground is invisible")
        }
    }
}
