// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import CoreGraphics
import Foundation
import XCTest

nonisolated final class WatchHomePaletteTests: XCTestCase {
    func testPaletteHexConstants() {
        XCTAssertEqual(WatchHomePalette.cream, "#F4EEE4")
        XCTAssertEqual(WatchHomePalette.calm, "#B8B8C0")
        XCTAssertEqual(WatchHomePalette.liveText, "#F2A457")
        XCTAssertEqual(WatchHomePalette.inFlight, "#F5A842")
        XCTAssertEqual(WatchHomePalette.alert, "#FF6B5E")
        XCTAssertEqual(WatchHomePalette.reducedContentOpacity, 0.60)
    }

    func testHexForRoleMapping() {
        XCTAssertEqual(WatchHomePalette.hex(for: .live), "#F2A457")
        XCTAssertEqual(WatchHomePalette.hex(for: .flight), "#F5A842")
        XCTAssertEqual(WatchHomePalette.hex(for: .calm), "#B8B8C0")
        XCTAssertEqual(WatchHomePalette.hex(for: .alert), "#FF6B5E")
    }

    func testWCAGContrastContract() {
        let placement = SunArcPlacement(size: CGSize(width: 200, height: 200), tipRadius: 40)
        let dayDrawing = sunArcCanvasDrawing(
            time: SunArcTime(t: 0.5, night: 0, q: 0.5),
            envelope: 1,
            sunPosition: .zero,
            placement: placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true
        )
        let nightDrawing = sunArcCanvasDrawing(
            time: SunArcTime(t: 0.5, night: 1, q: 0.5),
            envelope: 1,
            sunPosition: .zero,
            placement: placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true
        )

        let dayGround = dayDrawing.groundHex
        let nightGround = nightDrawing.groundHex
        let dayTonalSun = dayDrawing.beamHex
        let nightTonalSun = nightDrawing.beamHex

        XCTAssertEqual(dayGround, SunArcGround.currentGround(dayGroundHex: SunArc.inkHex, night: 0))
        XCTAssertEqual(nightGround, SunArcGround.currentGround(dayGroundHex: SunArc.inkHex, night: 1))
        XCTAssertEqual(
            dayTonalSun,
            SunArcOKLab.mix(SunArcGround.currentGround(dayGroundHex: SunArc.inkHex, night: 0), "#FCF3E4", 0.09)
        )
        XCTAssertEqual(
            nightTonalSun,
            SunArcOKLab.mix(SunArcGround.currentGround(dayGroundHex: SunArc.inkHex, night: 1), "#FCF3E4", 0.09)
        )

        let allForegrounds = [
            WatchHomePalette.cream,
            WatchHomePalette.calm,
            WatchHomePalette.liveText,
            WatchHomePalette.inFlight,
            WatchHomePalette.alert,
        ]
        let backgrounds = [dayGround, nightGround, dayTonalSun, nightTonalSun]

        for fg in allForegrounds {
            for bg in backgrounds {
                let ratio = Self.contrastRatio(hex1: fg, hex2: bg)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "Contrast between \(fg) and \(bg) is \(ratio), expected >= 4.5"
                )
            }
        }

        // Peak active-day glow composite check for non-alert foregrounds
        let activeDayDrawing = sunArcCanvasDrawing(
            time: SunArcTime(t: 0.5, night: 0, q: 0.5),
            envelope: 1,
            sunPosition: .zero,
            placement: placement,
            dayGroundHex: SunArc.inkHex,
            tonalSun: true,
            gateDayGlow: true,
            captureIsActive: true,
            luminanceReduced: false
        )
        let glowAlpha = activeDayDrawing.glowAlpha
        let goldRgb = SunArcOKLab.rgb(fromHex: SunArc.goldHex)
        let groundRgb = SunArcOKLab.rgb(fromHex: activeDayDrawing.groundHex)
        let compositeR = goldRgb.r * glowAlpha + groundRgb.r * (1 - glowAlpha)
        let compositeG = goldRgb.g * glowAlpha + groundRgb.g * (1 - glowAlpha)
        let compositeB = goldRgb.b * glowAlpha + groundRgb.b * (1 - glowAlpha)
        let compositeLuminance = Self.relativeLuminance(r: compositeR, g: compositeG, b: compositeB)

        let nonAlertForegrounds = [
            WatchHomePalette.cream,
            WatchHomePalette.calm,
            WatchHomePalette.liveText,
            WatchHomePalette.inFlight,
        ]

        for fg in nonAlertForegrounds {
            let fgLum = Self.relativeLuminance(hex: fg)
            let glowRatio = Self.contrastRatio(l1: fgLum, l2: compositeLuminance)
            XCTAssertGreaterThanOrEqual(
                glowRatio,
                4.5,
                "Glow composite contrast for \(fg) is \(glowRatio), expected >= 4.5"
            )
        }

        // Fixed floor #4C4120 contrast check
        let floorHex = "#4C4120"
        let calmRatio = Self.contrastRatio(hex1: WatchHomePalette.calm, hex2: floorHex)
        let liveTextRatio = Self.contrastRatio(hex1: WatchHomePalette.liveText, hex2: floorHex)
        let inFlightRatio = Self.contrastRatio(hex1: WatchHomePalette.inFlight, hex2: floorHex)
        let creamRatio = Self.contrastRatio(hex1: WatchHomePalette.cream, hex2: floorHex)

        XCTAssertGreaterThanOrEqual(calmRatio, 4.5)
        XCTAssertEqual(calmRatio, 5.11, accuracy: 0.05)

        XCTAssertGreaterThanOrEqual(liveTextRatio, 4.5)
        XCTAssertEqual(liveTextRatio, 4.90, accuracy: 0.05)

        XCTAssertGreaterThanOrEqual(inFlightRatio, 4.5)
        XCTAssertEqual(inFlightRatio, 5.07, accuracy: 0.05)

        XCTAssertGreaterThanOrEqual(creamRatio, 4.5)
        XCTAssertEqual(creamRatio, 8.73, accuracy: 0.05)
    }

    private static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        let adjust: (Double) -> Double = { c in
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * adjust(r) + 0.7152 * adjust(g) + 0.0722 * adjust(b)
    }

    private static func relativeLuminance(hex: String) -> Double {
        let rgb = SunArcOKLab.rgb(fromHex: hex)
        return relativeLuminance(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    private static func contrastRatio(l1: Double, l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func contrastRatio(hex1: String, hex2: String) -> Double {
        contrastRatio(l1: relativeLuminance(hex: hex1), l2: relativeLuminance(hex: hex2))
    }
}
