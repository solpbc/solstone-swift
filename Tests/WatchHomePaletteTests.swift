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
        XCTAssertEqual(WatchHomePalette.ground, "#1A1A1A")
    }

    func testHexForRoleMapping() {
        XCTAssertEqual(WatchHomePalette.hex(for: .live), "#F2A457")
        XCTAssertEqual(WatchHomePalette.hex(for: .flight), "#F5A842")
        XCTAssertEqual(WatchHomePalette.hex(for: .calm), "#B8B8C0")
        XCTAssertEqual(WatchHomePalette.hex(for: .alert), "#FF6B5E")
    }

    func testEveryTextRoleClearsTheInkGround() {
        // The active face is brand ink with no sun arc (founder, 2026-09-23, the bi-modal
        // watch). Measured: cream 15.08, calm 8.83, live 8.47, in flight 8.75, alert 6.23.
        let expected: [(String, Double)] = [
            (WatchHomePalette.cream, 15.08),
            (WatchHomePalette.calm, 8.83),
            (WatchHomePalette.liveText, 8.47),
            (WatchHomePalette.inFlight, 8.75),
            (WatchHomePalette.alert, 6.23),
        ]
        for (fg, _) in expected {
            let ratio = Self.contrastRatio(hex1: fg, hex2: WatchHomePalette.ground)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fg) on ink is \(ratio)")
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
