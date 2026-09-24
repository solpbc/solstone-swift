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
        let style = watchHomeControlStyle(isRunning: true)
        XCTAssertEqual(style.label, "stop")
        XCTAssertEqual(style.fillHex, "#3A3632")
        XCTAssertEqual(style.labelHex, WatchHomePalette.cream)
        XCTAssertEqual(style.labelAlpha, 1.0)
        XCTAssertNil(style.strokeHex)
        XCTAssertEqual(style.strokeAlpha, 0.0)
        XCTAssertEqual(style.strokeLineWidth, 0.0)
    }

    func testNotRunningNotReduced() {
        let style = watchHomeControlStyle(isRunning: false)
        XCTAssertEqual(style.label, "start")
        XCTAssertEqual(style.fillHex, SunArc.orangeHex)
        XCTAssertEqual(style.labelHex, SunArc.inkHex)
        XCTAssertEqual(style.labelAlpha, 1.0)
        XCTAssertNil(style.strokeHex)
        XCTAssertEqual(style.strokeAlpha, 0.0)
        XCTAssertEqual(style.strokeLineWidth, 0.0)
    }

    func testTheControlsLabelsClearTheirFills() {
        // The control only draws on the active face; its labels sit on their own fills.
        let start = watchHomeControlStyle(isRunning: false)
        let stop = watchHomeControlStyle(isRunning: true)
        XCTAssertGreaterThanOrEqual(Self.contrast(start.labelHex, start.fillHex!), 4.5)
        XCTAssertGreaterThanOrEqual(Self.contrast(stop.labelHex, stop.fillHex!), 4.5)
    }

    private static func contrast(_ a: String, _ b: String) -> Double {
        func lum(_ hex: String) -> Double {
            let c = SunArcOKLab.rgb(fromHex: hex)
            func l(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * l(c.r) + 0.7152 * l(c.g) + 0.0722 * l(c.b)
        }
        let x = lum(a), y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
