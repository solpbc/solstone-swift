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
        XCTAssertEqual(WatchHomePalette.calm, "#D9D9E1")
        XCTAssertEqual(WatchHomePalette.liveText, "#F2A457")
        XCTAssertEqual(WatchHomePalette.inFlight, "#F5A842")
        XCTAssertEqual(WatchHomePalette.alert, "#FF6B5E")
        XCTAssertEqual(WatchHomePalette.reducedContentOpacity, 0.60)
    }

    func testHexForRoleMapping() {
        XCTAssertEqual(WatchHomePalette.hex(for: .live), "#F2A457")
        XCTAssertEqual(WatchHomePalette.hex(for: .flight), "#F5A842")
        XCTAssertEqual(WatchHomePalette.hex(for: .calm), "#D9D9E1")
        XCTAssertEqual(WatchHomePalette.hex(for: .alert), "#FF6B5E")
    }

    /// The brightest background the sun arc's dark row puts under watch text, measured
    /// 2026-09-23 by drawing `SUNARC.both()` with the real mark (headless Chrome, 208 × 248 pt,
    /// every minute of Denver 2026-09-23, x 14–194 / y 0–165 pt, the area text can scroll
    /// through): with capture on, a 0.20 gold beam over the halo near the dawn corner; with
    /// capture off, the sun over the twilight glow.
    static let worstPatternBackgroundCaptureOn = "#725B2B"
    static let worstPatternBackgroundCaptureOff = "#6B542A"

    func testCalmAndCreamClearTheWorstPatternBackground() {
        for fg in [WatchHomePalette.cream, WatchHomePalette.calm] {
            for bg in [Self.worstPatternBackgroundCaptureOn, Self.worstPatternBackgroundCaptureOff] {
                let ratio = Self.contrastRatio(hex1: fg, hex2: bg)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fg) over \(bg) is \(ratio)")
            }
        }
        // ⚠ Open, 2026-09-23 (a founder question, not a build call): live text, in-flight and
        // alert measure 3.2–3.3, 3.3 and 2.4:1 over the same backgrounds. Clearing 4.5 would
        // turn live and in-flight into one pale peach and alert into pale pink, so they are
        // held at their 09-22 values until he rules. They clear 4.5 over every ground (below).
    }

    func testEveryTextRoleClearsTheDarkRowsGrounds() {
        let foregrounds = [
            WatchHomePalette.cream,
            WatchHomePalette.calm,
            WatchHomePalette.liveText,
            WatchHomePalette.inFlight,
            WatchHomePalette.alert,
        ]
        for fg in foregrounds {
            for bg in [SunArcGrounds.dark.day, SunArcGrounds.dark.night, SunArcGrounds.dark.deep] {
                let ratio = Self.contrastRatio(hex1: fg, hex2: bg)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fg) on \(bg) is \(ratio)")
            }
        }
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
