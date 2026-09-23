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
        let placement = SunArcPlacement(size: CGSize(width: 208, height: 248), tipRadius: SunArc.phi * 104)
        // Midday on the dark row: the sun is up, the twilight glow is out.
        let time = SunArcTime.compute(minutes: 780, riseMinutes: 408.26, setMinutes: 1135.65)
        let twilight = SunArcTwilight.compute(time: time, envelope: 1)

        let drawing = sunArcCanvasDrawing(
            time: time,
            envelope: 1.0,
            twilight: twilight,
            placement: placement,
            grounds: .dark,
            appearance: .dark,
            luminanceReduced: true
        )
        XCTAssertEqual(drawing.groundHex, "#000000")
        XCTAssertFalse(drawing.drawSun)
        XCTAssertEqual(drawing.sunOpacity, 0)
        XCTAssertNil(drawing.glow(.twilight))
        // The 0.22 halo is held to 0.12.
        XCTAssertEqual(drawing.glow(.halo)?.alpha ?? 0, 0.12, accuracy: 1e-6)
    }
}
