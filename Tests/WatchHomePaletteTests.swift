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
        XCTAssertEqual(WatchHomePalette.liveText, "#FED0A7")
        XCTAssertEqual(WatchHomePalette.inFlight, "#FFD19E")
        XCTAssertEqual(WatchHomePalette.alert, "#FECEC7")
        XCTAssertEqual(WatchHomePalette.reducedContentOpacity, 0.60)
    }

    func testHexForRoleMapping() {
        XCTAssertEqual(WatchHomePalette.hex(for: .live), "#FED0A7")
        XCTAssertEqual(WatchHomePalette.hex(for: .flight), "#FFD19E")
        XCTAssertEqual(WatchHomePalette.hex(for: .calm), "#D9D9E1")
        XCTAssertEqual(WatchHomePalette.hex(for: .alert), "#FECEC7")
    }

    /// The brightest background the sun arc's dark row puts under watch text, measured
    /// 2026-09-23 by drawing `SUNARC.both()` with the real mark (headless Chrome, 208 × 248 pt,
    /// every minute of Denver 2026-09-23, x 14–194 / y 0–165 pt, the area text can scroll
    /// through, the day halo always on): a 0.20 gold beam over the halo near the dawn corner.
    /// The hero band alone (y 55–165) peaks at `#6F5A2A`.
    static let worstPatternBackground = "#725B2B"
    static let worstHeroBandBackground = "#6F5A2A"

    func testEveryTextRoleClearsTheWorstPatternBackground() {
        // Founder, 2026-09-23: every watch text role clears 4.5:1 everywhere in the text area,
        // over the midday sun and halo included.
        let foregrounds = [
            WatchHomePalette.cream,
            WatchHomePalette.calm,
            WatchHomePalette.liveText,
            WatchHomePalette.inFlight,
            WatchHomePalette.alert,
        ]
        for fg in foregrounds {
            for bg in [Self.worstPatternBackground, Self.worstHeroBandBackground] {
                let ratio = Self.contrastRatio(hex1: fg, hex2: bg)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fg) over \(bg) is \(ratio)")
            }
        }
        XCTAssertNotEqual(WatchHomePalette.liveText, WatchHomePalette.inFlight)
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
