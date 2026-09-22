// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

nonisolated final class WatchSunArcDrawingTests: XCTestCase {
    private let placement = SunArcPlacement(size: CGSize(width: 200, height: 200), tipRadius: 40)
    private let sunPosition = CGPoint(x: 120, y: 80)

    func testDayGatedNotActiveProducesZeroAlphaAtSunPosition() {
        let testTimes = [
            SunArcTime(t: 0.5, night: 0.0, q: 0.5),
            SunArcTime(t: 0.5, night: 0.5, q: 0.5),
        ]

        for time in testTimes {
            let drawing = sunArcCanvasDrawing(
                time: time,
                envelope: 1.0,
                sunPosition: self.sunPosition,
                placement: self.placement,
                dayGroundHex: SunArc.inkHex,
                tonalSun: true,
                gateDayGlow: true,
                captureIsActive: false,
                luminanceReduced: false
            )
            XCTAssertEqual(drawing.glowAlpha, 0.0, accuracy: 1e-6)
            XCTAssertEqual(drawing.glowPosition, self.sunPosition)
        }
    }

    func testDayGatedActiveProducesExpectedFormulaAtSunPosition() {
        let testTimes = [
            SunArcTime(t: 0.5, night: 0.0, q: 0.5),
            SunArcTime(t: 0.5, night: 0.5, q: 0.5),
        ]

        for time in testTimes {
            let envelope = 0.8
            let expectedAlpha = SunArc.glowDayAlpha * envelope * (1.0 - time.night)
            let drawing = sunArcCanvasDrawing(
                time: time,
                envelope: envelope,
                sunPosition: self.sunPosition,
                placement: self.placement,
                dayGroundHex: SunArc.inkHex,
                tonalSun: true,
                gateDayGlow: true,
                captureIsActive: true,
                luminanceReduced: false
            )
            XCTAssertEqual(drawing.glowAlpha, expectedAlpha, accuracy: 1e-6)
            XCTAssertEqual(drawing.glowPosition, self.sunPosition)
        }
    }

    func testNightMatchesComputeForBothCaptureStates() {
        let nightTime = SunArcTime(t: -0.1, night: 1.0, q: 0.2)
        let expectedCompute = SunArcGlow.compute(
            time: nightTime,
            sunPosition: self.sunPosition,
            envelope: 1.0,
            onVisible: false,
            placement: self.placement
        )

        for captureActive in [false, true] {
            let drawing = sunArcCanvasDrawing(
                time: nightTime,
                envelope: 1.0,
                sunPosition: self.sunPosition,
                placement: self.placement,
                dayGroundHex: SunArc.inkHex,
                tonalSun: true,
                gateDayGlow: true,
                captureIsActive: captureActive,
                luminanceReduced: false
            )
            XCTAssertEqual(drawing.glowAlpha, expectedCompute.alpha, accuracy: 1e-6)
            XCTAssertEqual(drawing.glowPosition, expectedCompute.position)
        }
    }

    func testTonalFillAndOpacity() {
        let time = SunArcTime(t: 0.5, night: 0.2, q: 0.5)
        let dayGround = SunArc.inkHex
        let currentGround = SunArcGround.currentGround(dayGroundHex: dayGround, night: time.night)
        let expectedTonalHex = SunArcOKLab.mix(currentGround, "#FCF3E4", 0.09)
        let envelope = 0.9

        let drawing = sunArcCanvasDrawing(
            time: time,
            envelope: envelope,
            sunPosition: self.sunPosition,
            placement: self.placement,
            dayGroundHex: dayGround,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: true,
            luminanceReduced: false
        )
        XCTAssertEqual(drawing.beamHex, expectedTonalHex)
        XCTAssertEqual(drawing.ringHex, expectedTonalHex)
        XCTAssertEqual(drawing.sunOpacity, envelope * (1.0 - time.night), accuracy: 1e-6)
        XCTAssertTrue(drawing.drawSun)

        // Outside window (e.g. t = -0.05)
        let outsideTime = SunArcTime(t: -0.05, night: 0.2, q: 0.5)
        let outsideDrawing = sunArcCanvasDrawing(
            time: outsideTime,
            envelope: envelope,
            sunPosition: self.sunPosition,
            placement: self.placement,
            dayGroundHex: dayGround,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: true,
            luminanceReduced: false
        )
        XCTAssertEqual(outsideDrawing.sunOpacity, 0.0, accuracy: 1e-6)
        XCTAssertFalse(outsideDrawing.drawSun)

        // Default non-tonal opacity
        let defaultDrawing = sunArcCanvasDrawing(
            time: time,
            envelope: envelope,
            sunPosition: self.sunPosition,
            placement: self.placement,
            dayGroundHex: dayGround,
            tonalSun: false,
            gateDayGlow: false,
            captureIsActive: false,
            luminanceReduced: false
        )
        XCTAssertEqual(defaultDrawing.sunOpacity, SunArc.peakOpacity * envelope * (1.0 - time.night), accuracy: 1e-6)
        XCTAssertEqual(defaultDrawing.beamHex, SunArc.goldHex)
        XCTAssertEqual(defaultDrawing.ringHex, SunArc.orangeHex)
    }

    func testWatchGround() {
        let dayDrawing = sunArcCanvasDrawing(
            time: SunArcTime(t: 0.5, night: 0.0, q: 0.5),
            envelope: 1.0,
            sunPosition: self.sunPosition,
            placement: self.placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: true,
            luminanceReduced: false
        )
        XCTAssertEqual(dayDrawing.groundHex, SunArc.inkHex)

        let nightDrawing = sunArcCanvasDrawing(
            time: SunArcTime(t: 0.5, night: 1.0, q: 0.5),
            envelope: 1.0,
            sunPosition: self.sunPosition,
            placement: self.placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: true,
            luminanceReduced: false
        )
        let expectedNightGround = SunArcGround.nightGround(dayGroundHex: SunArc.inkHex)
        XCTAssertEqual(nightDrawing.groundHex, expectedNightGround)
    }

    func testLuminanceReducedBlackGroundNoSunGlowCap() {
        let peakDayTime = SunArcTime(t: 0.5, night: 0.0, q: 0.5)

        // Active day peak: 0.22 capped to 0.12
        let activeReduced = sunArcCanvasDrawing(
            time: peakDayTime,
            envelope: 1.0,
            sunPosition: self.sunPosition,
            placement: self.placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: true,
            luminanceReduced: true
        )
        XCTAssertEqual(activeReduced.groundHex, "#000000")
        XCTAssertFalse(activeReduced.drawSun)
        XCTAssertEqual(activeReduced.sunOpacity, 0)
        XCTAssertEqual(activeReduced.glowAlpha, SunArc.glowNightFloor, accuracy: 1e-6)

        // Not active day: 0 remains 0
        let idleReduced = sunArcCanvasDrawing(
            time: peakDayTime,
            envelope: 1.0,
            sunPosition: self.sunPosition,
            placement: self.placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: false,
            luminanceReduced: true
        )
        XCTAssertEqual(idleReduced.groundHex, "#000000")
        XCTAssertFalse(idleReduced.drawSun)
        XCTAssertEqual(idleReduced.sunOpacity, 0)
        XCTAssertEqual(idleReduced.glowAlpha, 0, accuracy: 1e-6)
    }

    func testIOSDefaultsMatchDenverMoments() {
        let denverTZ = TimeZone(identifier: "America/Denver")!
        let palette = SunArcGroundPalette(dayGroundHex: "#FCF3E4")
        let instants: [TimeInterval] = [1_789_820_040, 1_789_843_980, 1_789_876_800]
        let sceneSize = CGSize(width: 400, height: 800)
        let diameter = SunArc.phi * Double(min(sceneSize.width, sceneSize.height))
        let placement = SunArcPlacement(size: sceneSize, tipRadius: diameter / 2)

        for instant in instants {
            let date = Date(timeIntervalSince1970: instant)
            let moment = SunArcBackgroundMoment.resolve(
                date: date,
                timeZone: denverTZ,
                palette: palette,
                presentationCoordinate: nil
            )

            let clampedT = min(1, max(0, moment.time.t))
            let scenePosition = placement.position(at: clampedT)
            let onVisible = moment.time.t > -0.02 && moment.time.t < 1.02

            let drawing = sunArcCanvasDrawing(
                time: moment.time,
                envelope: moment.envelope,
                sunPosition: scenePosition,
                placement: placement,
                dayGroundHex: palette.dayGroundHex,
                tonalSun: false,
                gateDayGlow: false,
                captureIsActive: false,
                luminanceReduced: false
            )

            let expectedGlow = SunArcGlow.compute(
                time: moment.time,
                sunPosition: scenePosition,
                envelope: moment.envelope,
                onVisible: onVisible,
                placement: placement
            )
            let expectedOpacity = onVisible
                ? SunArc.peakOpacity * moment.envelope * (1.0 - moment.time.night)
                : 0.0

            XCTAssertEqual(drawing.glowPosition, expectedGlow.position)
            XCTAssertEqual(drawing.glowAlpha, expectedGlow.alpha, accuracy: 1e-6)
            XCTAssertEqual(drawing.sunOpacity, expectedOpacity, accuracy: 1e-6)
            XCTAssertEqual(drawing.beamHex, SunArc.goldHex)
            XCTAssertEqual(drawing.ringHex, SunArc.orangeHex)
            XCTAssertEqual(drawing.groundHex, moment.groundHex)
        }
    }
}
