// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

nonisolated final class WatchHomeLuminanceSourceTests: XCTestCase {
    func testReducedContentOpacityConstant() {
        XCTAssertEqual(WatchHomePalette.reducedContentOpacity, 0.60)
    }

    func testLuminanceReducedDrawingResult() {
        let placement = SunArcPlacement(size: CGSize(width: 200, height: 200), tipRadius: 40)
        let sunPosition = CGPoint(x: 100, y: 100)
        let dayTime = SunArcTime(t: 0.5, night: 0, q: 0.5)

        // Active day with reduced luminance
        let activeDrawing = sunArcCanvasDrawing(
            time: dayTime,
            envelope: 1.0,
            sunPosition: sunPosition,
            placement: placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: true,
            luminanceReduced: true
        )
        XCTAssertEqual(activeDrawing.groundHex, "#000000")
        XCTAssertFalse(activeDrawing.drawSun)
        XCTAssertEqual(activeDrawing.sunOpacity, 0)
        XCTAssertEqual(activeDrawing.glowAlpha, 0.12, accuracy: 1e-6)

        // Not-active day with reduced luminance
        let idleDrawing = sunArcCanvasDrawing(
            time: dayTime,
            envelope: 1.0,
            sunPosition: sunPosition,
            placement: placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: false,
            luminanceReduced: true
        )
        XCTAssertEqual(idleDrawing.groundHex, "#000000")
        XCTAssertFalse(idleDrawing.drawSun)
        XCTAssertEqual(idleDrawing.sunOpacity, 0)
        XCTAssertEqual(idleDrawing.glowAlpha, 0, accuracy: 1e-6)
    }
}
