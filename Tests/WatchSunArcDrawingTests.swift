// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

/// The watch draws the sun arc's dark appearance at every hour (founder, 2026-09-23), with the
/// two 09-22 rules that stand: the day halo only while capture is on, and wrist-down black with
/// the sun off and every glow capped at 0.12.
nonisolated final class WatchSunArcDrawingTests: XCTestCase {
    // The watch's face, Series 11 46 mm, in points.
    private let placement = SunArcPlacement(size: CGSize(width: 208, height: 248), tipRadius: SunArc.phi * 208 / 2)
    // Denver, 2026-09-23, the reference's own sunrise and sunset.
    private let rise = 408.25991130150896
    private let set = 1135.6484964224096

    private func drawing(
        minutes: Double,
        captureIsActive: Bool,
        luminanceReduced: Bool = false
    ) -> (SunArcTime, SunArcCanvasDrawing) {
        let moment = SunArcBackgroundMoment.at(
            minutes: minutes,
            riseMinutes: self.rise,
            setMinutes: self.set,
            grounds: .dark,
            appearance: .dark
        )
        return (moment.time, moment.drawing(
            sceneSize: CGSize(width: 208, height: 248),
            gateDayGlow: true,
            captureIsActive: captureIsActive,
            luminanceReduced: luminanceReduced
        ).drawing)
    }

    func testTheDayHaloShowsOnlyWhileCaptureIsOn() {
        for minutes in [600.0, 780, 1000] {
            let (_, off) = self.drawing(minutes: minutes, captureIsActive: false)
            XCTAssertNil(off.glow(.halo), "no halo at \(minutes) while capture is off")

            let (time, on) = self.drawing(minutes: minutes, captureIsActive: true)
            let halo = on.glow(.halo)
            XCTAssertNotNil(halo)
            let expected = SunArc.glowDayAlpha * SunArcEnvelope.value(at: time.t) * (1 - time.night)
            XCTAssertEqual(halo?.alpha ?? -1, expected, accuracy: 1e-9)
            XCTAssertEqual(halo?.radius ?? 0, SunArc.phi * self.placement.tipRadius, accuracy: 1e-9)
            XCTAssertEqual(halo?.center, self.placement.position(at: time.t))
        }
    }

    func testTheTwilightGlowIsTheTimeOfDayAndIsNeverGatedByCapture() {
        for minutes in [1136.0, 1181, 1320, 330] {
            let (_, off) = self.drawing(minutes: minutes, captureIsActive: false)
            let (_, on) = self.drawing(minutes: minutes, captureIsActive: true)
            XCTAssertNotNil(off.glow(.twilight), "twilight glow at \(minutes) with capture off")
            XCTAssertEqual(off.glow(.twilight), on.glow(.twilight))
        }
        // dusk + 15: the dark row's gold-to-orange, φ²R, 0.62 × w.
        let (_, dusk) = self.drawing(minutes: 1181, captureIsActive: false)
        let glow = dusk.glow(.twilight)
        XCTAssertEqual(glow?.radius ?? 0, SunArc.twilightRadiusRatio * self.placement.tipRadius, accuracy: 1e-9)
        XCTAssertEqual(glow?.alpha ?? 0, 0.62 * 0.993676, accuracy: 0.001)
        XCTAssertEqual(glow?.colorHex, "#F8B836")
    }

    func testTheWatchDrawsTheDarkRowAtEveryHour() {
        XCTAssertEqual(self.drawing(minutes: 780, captureIsActive: true).1.groundHex, "#392E26")
        XCTAssertEqual(self.drawing(minutes: 1181, captureIsActive: true).1.groundHex, "#2E241C")
        XCTAssertEqual(self.drawing(minutes: 60, captureIsActive: true).1.groundHex, "#281E17")
        XCTAssertTrue(self.drawing(minutes: 60, captureIsActive: true).1.glows.isEmpty, "true dark has no glow")
        for minutes in stride(from: 0.0, to: 1440, by: 15) {
            let ground = self.drawing(minutes: minutes, captureIsActive: false).1.groundHex
            XCTAssertLessThan(SunArcOKLab.lightness(ofHex: ground), 0.5, "\(ground) at \(minutes)")
        }
    }

    func testTheSunIsTheColourMarkAtPointTwoAndNeverTonal() {
        let (_, midday) = self.drawing(minutes: 780, captureIsActive: false)
        XCTAssertTrue(midday.drawSun)
        XCTAssertEqual(midday.sunOpacity, SunArc.peakOpacityDark, accuracy: 1e-9)
        XCTAssertEqual(midday.beamHex, SunArc.goldHex)
        XCTAssertEqual(midday.ringHex, SunArc.orangeHex)

        let (_, night) = self.drawing(minutes: 1320, captureIsActive: true)
        XCTAssertFalse(night.drawSun)
        XCTAssertEqual(night.sunOpacity, 0)
    }

    func testWristDownIsBlackWithTheSunOffAndEveryGlowCapped() {
        // 23:10 is late enough that 0.62 × w is under the cap and must be left alone.
        XCTAssertLessThan(self.drawing(minutes: 1390, captureIsActive: false).1.glow(.twilight)?.alpha ?? 1, SunArc.wristDownGlowCap)
        for minutes in [780.0, 1136, 1181, 330, 1390] {
            for captureIsActive in [false, true] {
                let (_, full) = self.drawing(minutes: minutes, captureIsActive: captureIsActive)
                let (_, reduced) = self.drawing(minutes: minutes, captureIsActive: captureIsActive, luminanceReduced: true)
                XCTAssertEqual(reduced.groundHex, "#000000")
                XCTAssertFalse(reduced.drawSun)
                XCTAssertEqual(reduced.sunOpacity, 0)
                XCTAssertEqual(reduced.glows.map(\.kind), full.glows.map(\.kind))
                for (capped, uncapped) in zip(reduced.glows, full.glows) {
                    XCTAssertEqual(capped.alpha, min(uncapped.alpha, SunArc.wristDownGlowCap), accuracy: 1e-9)
                }
            }
        }
        // Dusk + 15, capture off: the twilight glow is capped, not removed.
        let duskDown = self.drawing(minutes: 1181, captureIsActive: false, luminanceReduced: true).1
        XCTAssertEqual(duskDown.glow(.twilight)?.alpha ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertNil(duskDown.glow(.halo))
        // Midday, capture on: the 0.22 halo is held to 0.12; capture off: no halo at all.
        XCTAssertEqual(self.drawing(minutes: 780, captureIsActive: true, luminanceReduced: true).1.glow(.halo)?.alpha ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertNil(self.drawing(minutes: 780, captureIsActive: false, luminanceReduced: true).1.glow(.halo))
    }

    func testIOSDrawsTheOwnersAppearanceWithAnUngatedHalo() {
        let denverTZ = TimeZone(identifier: "America/Denver")!
        let palette = SunArcGroundPalette(lightDayHex: "#FCF3E4")
        let sceneSize = CGSize(width: 400, height: 800)
        let placement = SunArcPlacement(size: sceneSize, tipRadius: SunArc.phi * 400 / 2)
        for instant: TimeInterval in [1_789_820_040, 1_789_843_980, 1_789_876_800] {
            for appearance in [SunArcAppearance.light, .dark] {
                let moment = SunArcBackgroundMoment.resolve(
                    date: Date(timeIntervalSince1970: instant),
                    timeZone: denverTZ,
                    palette: palette,
                    appearance: appearance,
                    presentationCoordinate: nil
                )
                let drawing = sunArcCanvasDrawing(
                    time: moment.time,
                    envelope: moment.envelope,
                    twilight: moment.twilight,
                    placement: placement,
                    grounds: moment.grounds,
                    appearance: moment.appearance
                )
                XCTAssertEqual(drawing.groundHex, moment.groundHex)
                XCTAssertEqual(moment.grounds, appearance == .light ? SunArcGrounds.light(day: "#FCF3E4") : .dark)
                let onVisible = moment.time.t > -0.02 && moment.time.t < 1.02
                if moment.time.night < 1, onVisible {
                    XCTAssertNotNil(drawing.glow(.halo), "iOS draws the halo whether or not anything is capturing")
                }
                let peak = appearance == .light ? SunArc.peakOpacityLight : SunArc.peakOpacityDark
                let expectedOpacity = onVisible ? peak * moment.envelope * (1 - moment.time.night) : 0
                XCTAssertEqual(drawing.sunOpacity, expectedOpacity, accuracy: 1e-6)
            }
        }
    }
}
