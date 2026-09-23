// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// Verifies the ported sun-arc geometry against numbers computed from the canonical JS kernel
/// (`cmo/brand/sbis/kernel/{sol-geo,sol-ulm}.js` + `cmo/brand/sbis/patterns/sun-arc/sunarc.js` in
/// the extro repo) at 720×500 — the one window size this app itself defines
/// (`.frame(minWidth: 720, minHeight: 500)`), used here as the § 12 acceptance render's
/// "stated representative window size."
@Suite("SunArc engine — macOS acceptance render at 720×500")
struct SunArcEngineTests {
    static let size = CGSize(width: 720, height: 500)
    static let tipRadius: Double = 404.5 // phi * min(720,500) / 2

    @Test func diameterAndTipRadiusMatchTheWorkedNumbers() {
        let side = min(Self.size.width, Self.size.height)
        let diameter = SunArc.phi * Double(side)
        #expect(abs(diameter - 809.0) < 0.05)
        #expect(abs(diameter / 2 - Self.tipRadius) < 0.05)
    }

    @Test func endsAreExactlyHiddenAtTZeroAndTOne() {
        // § 12: "At t = 0 and t = 1 no part of the sun is visible (the tip touches the corner exactly)."
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        #expect(abs(placement.a.x - (-286.0246929899585)) < 0.001)
        #expect(abs(placement.a.y - (-286.0246929899585)) < 0.001)
        #expect(abs(placement.b.x - 1006.0246929899585) < 0.001)
        #expect(abs(placement.b.y - 786.0246929899585) < 0.001)

        let atZero = placement.position(at: 0)
        let atOne = placement.position(at: 1)
        #expect(abs(atZero.x - placement.a.x) < 0.001)
        #expect(abs(atZero.y - placement.a.y) < 0.001)
        #expect(abs(atOne.x - placement.b.x) < 0.001)
        #expect(abs(atOne.y - placement.b.y) < 0.001)

        #expect(SunArcEnvelope.value(at: 0) == 0)
        #expect(SunArcEnvelope.value(at: 1) == 0)
    }

    @Test func midpointMatchesTheWorkedTableWithinOnePercent() {
        // § 12: "At t = ½ the centre matches the worked table for that frame's W × H within 1%."
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        let mid = placement.position(at: 0.5)
        let expectedX = 444.89797099934594, expectedY = 147.6797405649545
        #expect(abs(mid.x - expectedX) / abs(expectedX) < 0.01)
        #expect(abs(mid.y - expectedY) / abs(expectedY) < 0.01)

        #expect(abs(placement.chord - 1678.8929393475325) / placement.chord < 0.01)
        #expect(abs(placement.sagitta - 132.9552592816873) / placement.sagitta < 0.01)
        #expect(abs(placement.arcRadius - 2716.5058393365234) / placement.arcRadius < 0.01)
    }

    @Test func arcSubtendsThirtySixDegrees() {
        // § 12: "The arc subtends 36.0° ± 0.1° (compute 2·asin(c / 2Rarc))."
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        let degrees = 2 * asin(placement.chord / (2 * placement.arcRadius)) * 180 / .pi
        #expect(abs(degrees - 36.0) < 0.1)
    }

    @Test func peakOpacityIsPointFiveFiveOnLightPointTwoOnDarkAndZeroOutsideTheDay() {
        // § 12: "Opacity 0.55 at the plateau on a light ground and 0.20 on a dark ground; 0
        // outside the day."
        #expect(SunArc.peakOpacityLight == 0.55)
        #expect(SunArc.peakOpacityDark == 0.20)
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        let midday = SunArcTime.compute(minutes: 12 * 60, riseMinutes: 6 * 60 + 30, setMinutes: 19 * 60 + 30)
        let deepNight = SunArcTime.compute(minutes: 2 * 60, riseMinutes: 6 * 60 + 30, setMinutes: 19 * 60 + 30)
        #expect(deepNight.night == 1)
        for (appearance, peak) in [(SunArcAppearance.light, 0.55), (.dark, 0.20)] {
            let grounds = appearance == .light ? SunArcGrounds.light : SunArcGrounds.dark
            for (time, expected) in [(midday, peak), (deepNight, 0.0)] {
                let envelope = SunArcEnvelope.value(at: time.t)
                let drawing = sunArcCanvasDrawing(
                    time: time,
                    envelope: envelope,
                    twilight: SunArcTwilight.compute(time: time, envelope: envelope),
                    placement: placement,
                    grounds: grounds,
                    appearance: appearance
                )
                #expect(abs(drawing.sunOpacity - expected) < 0.001)
                #expect(drawing.beamHex == SunArc.goldHex)
                #expect(drawing.ringHex == SunArc.orangeHex)
            }
        }
    }

    @Test func positionUpdatesAtMostOnceAMinuteByConstruction() {
        // § 12: "Position updates at most once a minute; no timer under a minute." — the view
        // drives its Canvas from `TimelineView(.everyMinute)`, SwiftUI's own once-a-minute
        // schedule; this asserts the minute-quantization the schedule relies on, since the
        // schedule itself isn't unit-testable headlessly.
        let a = SunArcTime.minutesSinceMidnight(Date(timeIntervalSince1970: 1_726_750_020)) // arbitrary instant (00s)
        let b = SunArcTime.minutesSinceMidnight(Date(timeIntervalSince1970: 1_726_750_050)) // +30s, same minute (30s)
        #expect(a == b)
    }
}

/// Spec § 4a's worked numbers, from `SUNARC.both()` (`numbers.js` and a node run over the same
/// function): Denver 2026-09-23, iphone 393 × 852, rise 06:48 / set 18:56 as the reference
/// computes them. Every row in both appearances.
@Suite("SunArc both appearances — § 4a worked numbers")
struct SunArcBothAppearancesTests {
    static let size = CGSize(width: 393, height: 852)
    static let rise = 408.25991130150896
    static let set = 1135.6484964224096

    struct Glow { let x: Double; let y: Double; let alpha: Double; let hex: String }
    struct V {
        let minutes: Double
        let appearance: SunArcAppearance
        let ground: String
        let sunAlpha: Double
        let w: Double
        let phase: SunArcTwilight.Phase
        let halo: Double?
        let twilight: Glow?
        let corner: Double
    }

    static let vectors: [V] = [
        V(minutes: 780, appearance: .light, ground: "#FEFCF8", sunAlpha: 0.550000, w: 0.000000, phase: .day, halo: 0.220000, twilight: nil, corner: 0.0000), // 13:00
        V(minutes: 780, appearance: .dark, ground: "#392E26", sunAlpha: 0.200000, w: 0.000000, phase: .day, halo: 0.220000, twilight: nil, corner: 0.0000), // 13:00
        V(minutes: 1136, appearance: .light, ground: "#FEFCF7", sunAlpha: 0.144381, w: 0.734377, phase: .day, halo: 0.057752, twilight: Glow(x: 601.863, y: 1019.649, alpha: 0.697658, hex: "#FFE296"), corner: 0.3728), // 18:56 sunset
        V(minutes: 1136, appearance: .dark, ground: "#392E26", sunAlpha: 0.052502, w: 0.734377, phase: .day, halo: 0.057752, twilight: Glow(x: 601.863, y: 1019.649, alpha: 0.455314, hex: "#F9BA36"), corner: 0.2433), // 18:56 sunset
        V(minutes: 1181, appearance: .light, ground: "#E9DECC", sunAlpha: 0.000000, w: 0.993676, phase: .evening, halo: nil, twilight: Glow(x: 620.436, y: 1086.721, alpha: 0.943992, hex: "#FFE294"), corner: 0.4161), // 19:41 dusk + 15
        V(minutes: 1181, appearance: .dark, ground: "#2E241C", sunAlpha: 0.000000, w: 0.993676, phase: .evening, halo: nil, twilight: Glow(x: 620.436, y: 1086.721, alpha: 0.616079, hex: "#F8B836"), corner: 0.2716), // 19:41 dusk + 15
        V(minutes: 1320, appearance: .light, ground: "#DFD2BC", sunAlpha: 0.000000, w: 0.434138, phase: .evening, halo: nil, twilight: Glow(x: 642.278, y: 1176.833, alpha: 0.412431, hex: "#FFDC7F"), corner: 0.1521), // 22:00
        V(minutes: 1320, appearance: .dark, ground: "#2B2119", sunAlpha: 0.000000, w: 0.434138, phase: .evening, halo: nil, twilight: Glow(x: 642.278, y: 1176.833, alpha: 0.269166, hex: "#F1A739"), corner: 0.0993), // 22:00
        V(minutes: 60, appearance: .light, ground: "#D7C9B0", sunAlpha: 0.000000, w: 0.000000, phase: .trueDark, halo: nil, twilight: nil, corner: 0.0000), // 01:00
        V(minutes: 60, appearance: .dark, ground: "#281E17", sunAlpha: 0.000000, w: 0.000000, phase: .trueDark, halo: nil, twilight: nil, corner: 0.0000), // 01:00
        V(minutes: 330, appearance: .light, ground: "#E8DDCA", sunAlpha: 0.000000, w: 0.938094, phase: .beforeDawn, halo: nil, twilight: Glow(x: -249.940, y: -244.955, alpha: 0.891189, hex: "#FFE08F"), corner: 0.3749), // 05:30
        V(minutes: 330, appearance: .dark, ground: "#2E241C", sunAlpha: 0.000000, w: 0.938094, phase: .beforeDawn, halo: nil, twilight: Glow(x: -249.940, y: -244.955, alpha: 0.581618, hex: "#F6B437"), corner: 0.2447), // 05:30
        V(minutes: 408, appearance: .light, ground: "#FEFCF8", sunAlpha: 0.145264, w: 0.733576, phase: .day, halo: 0.058105, twilight: Glow(x: -179.052, y: -186.739, alpha: 0.696897, hex: "#FFE296"), corner: 0.3834), // 06:48 sunrise
        V(minutes: 408, appearance: .dark, ground: "#392E26", sunAlpha: 0.052823, w: 0.733576, phase: .day, halo: 0.058105, twilight: Glow(x: -179.052, y: -186.739, alpha: 0.454817, hex: "#F9BA36"), corner: 0.2502), // 06:48 sunrise
    ]

    static func moment(minutes: Double, appearance: SunArcAppearance, rise: Double = Self.rise, set: Double = Self.set) -> SunArcBackgroundMoment {
        SunArcBackgroundMoment.at(
            minutes: minutes,
            riseMinutes: rise,
            setMinutes: set,
            grounds: appearance == .light ? .light : .dark,
            appearance: appearance
        )
    }

    /// The same frame function the Canvas draws with.
    static func frame(minutes: Double, appearance: SunArcAppearance, rise: Double = Self.rise, set: Double = Self.set) -> SunArcCanvasDrawing {
        Self.moment(minutes: minutes, appearance: appearance, rise: rise, set: set).drawing(sceneSize: Self.size).drawing
    }

    /// `A.glowAt`: the gradient `a → 0.45a → 0` at 0 → 38 % → 100 % of the radius.
    static func glowAt(_ g: SunArcGlowLayer, _ x: Double, _ y: Double) -> Double {
        let f = hypot(x - Double(g.center.x), y - Double(g.center.y)) / g.radius
        if f >= 1 { return 0 }
        return f <= 0.38 ? g.alpha * (1 - 0.55 * f / 0.38) : g.alpha * 0.45 * (1 - (f - 0.38) / 0.62)
    }

    static func channelsWithinOne(_ a: String, _ b: String) -> Bool {
        let x = SunArcOKLab.rgb(fromHex: a), y = SunArcOKLab.rgb(fromHex: b)
        return [abs(x.r - y.r), abs(x.g - y.g), abs(x.b - y.b)].allSatisfy { $0 * 255 <= 1.01 }
    }

    @Test(arguments: Self.vectors.indices)
    func matchesTheWorkedNumbers(_ index: Int) {
        let v = Self.vectors[index]
        let moment = Self.moment(minutes: v.minutes, appearance: v.appearance)
        let twilight = moment.twilight
        let drawing = moment.drawing(sceneSize: Self.size).drawing
        #expect(abs(moment.drawing(sceneSize: Self.size).placement.tipRadius - 317.9437) < 0.001)

        #expect(Self.channelsWithinOne(drawing.groundHex, v.ground), "ground \(drawing.groundHex) vs \(v.ground)")
        #expect(abs(drawing.sunOpacity - v.sunAlpha) < 0.001)
        #expect(abs(twilight.w - v.w) < 0.0005)
        #expect(twilight.phase == v.phase)

        if let halo = v.halo {
            #expect(abs((drawing.glow(.halo)?.alpha ?? -1) - halo) < 0.001)
            #expect(abs((drawing.glow(.halo)?.radius ?? 0) - 514.444) < 0.01)
        } else {
            #expect(drawing.glow(.halo) == nil)
        }

        if let expected = v.twilight {
            let glow = drawing.glow(.twilight)
            #expect(glow != nil)
            guard let glow else { return }
            #expect(abs(Double(glow.center.x) - expected.x) < 0.5)
            #expect(abs(Double(glow.center.y) - expected.y) < 0.5)
            #expect(abs(glow.radius - 832.387) < 0.01)
            #expect(abs(glow.alpha - expected.alpha) < 0.001)
            #expect(Self.channelsWithinOne(glow.colorHex, expected.hex), "glow \(glow.colorHex) vs \(expected.hex)")
            let corner = max(Self.glowAt(glow, 393, 852), Self.glowAt(glow, 0, 0))
            #expect(abs(corner - v.corner) < 0.002)
        } else {
            #expect(drawing.glow(.twilight) == nil)
        }
    }

    @Test func theTrueDarkWindowIsThreeHoursAroundSolarMidnight() {
        // § 4a worked numbers: "true dark 23:21–02:21".
        let window = SunArcTwilight.trueDarkWindow(riseMinutes: Self.rise, setMinutes: Self.set)
        #expect(abs(window.from - (23 * 60 + 21.95)) < 0.1)
        #expect(abs(window.to - (2 * 60 + 21.95)) < 0.1)
        #expect(abs(window.mid - 51.95) < 0.1)
        // § 12: "Inside the true-dark window no glow is drawn and the ground is the true-dark ground."
        for minutes in Array(stride(from: 1402.0, through: 1439, by: 1)) + Array(stride(from: 0.0, through: 141, by: 1)) {
            for appearance in [SunArcAppearance.light, .dark] {
                let drawing = Self.frame(minutes: minutes, appearance: appearance)
                #expect(drawing.glows.isEmpty)
                #expect(drawing.groundHex == (appearance == .light ? SunArcGrounds.light.deep : SunArcGrounds.dark.deep))
            }
        }
    }

    @Test func theAcceptanceFloorsAtDuskPlusFifteenHold() {
        // § 12: "at dusk + 15 min its alpha at the dusk-side corner is ≥ 0.25 on dark and ≥ 0.40 on light."
        for (appearance, floor) in [(SunArcAppearance.dark, 0.25), (.light, 0.40)] {
            let glow = Self.frame(minutes: 1181, appearance: appearance).glow(.twilight)!
            #expect(Self.glowAt(glow, 393, 852) >= floor)
        }
    }

    @Test func contentNeverFlipsByClock() {
        // § 6: "every light ground sits above L 0.5 and every dark ground below it" — at every
        // minute of the day, the ground stays on the owner's appearance's side.
        for minutes in stride(from: 0.0, to: 1440, by: 1) {
            #expect(SunArcOKLab.lightness(ofHex: Self.frame(minutes: minutes, appearance: .light).groundHex) > 0.5)
            #expect(SunArcOKLab.lightness(ofHex: Self.frame(minutes: minutes, appearance: .dark).groundHex) < 0.5)
        }
        // The iOS deck's light day ground (tile cream) keeps the table's night and true dark.
        let deck = SunArcGrounds.light(day: "#FCF3E4")
        #expect(deck.night == SunArcGrounds.light.night)
        #expect(deck.deep == SunArcGrounds.light.deep)
    }

    @Test func aSunsetAfterMidnightStaysOnOneExtendedMinuteAxis() {
        // § 4a (canon update 2026-09-23, extro e56d376260): rise 175, set 3 (Reykjavik-like,
        // the sunset wrapped below sunrise), dark, 393 × 852 — values from `SUNARC.both()`.
        let rows: [(minutes: Double, phase: SunArcTwilight.Phase, w: Double, ground: String)] = [
            (10, .day, 0.8767, "#362C24"),
            (60, .evening, 0.6724, "#2C221A"),
            (120, .beforeDawn, 0.7165, "#2C221B"),
        ]
        for row in rows {
            let moment = Self.moment(minutes: row.minutes, appearance: .dark, rise: 175, set: 3)
            #expect(moment.twilight.phase == row.phase, "phase at \(row.minutes)")
            #expect(abs(moment.twilight.w - row.w) < 0.0005, "w at \(row.minutes): \(moment.twilight.w)")
            #expect(Self.channelsWithinOne(moment.groundHex, row.ground), "ground at \(row.minutes): \(moment.groundHex)")
        }
        // A night of 30 minutes gets no true dark at all (the window is max(0, span − 120)).
        let window = SunArcTwilight.trueDarkWindow(riseMinutes: 175, setMinutes: 3)
        #expect(abs(window.from - window.to) < 0.001)
        // Every minute: the hidden sun stays on its extended path, and while `SunArcTime`
        // says it is day the glow sits on the sun itself.
        for minutes in stride(from: 0.0, to: 1440, by: 1) {
            let moment = Self.moment(minutes: minutes, appearance: .dark, rise: 175, set: 3)
            #expect(moment.twilight.te >= -0.1 - 1e-9 && moment.twilight.te <= 1.1 + 1e-9)
            if moment.time.t >= 0, moment.time.t <= 1 {
                #expect(moment.twilight.phase == .day)
                #expect(moment.twilight.te == moment.time.t)
            }
        }
        // The same through the real solar chain: Reykjavik, 21 June 2026 (set > 1440).
        let june21 = Date(timeIntervalSince1970: 1_782_043_200)
        let pair = SunArcSolar.times(latitude: 64.1466, longitude: -21.9426, date: june21, utcOffsetMinutes: 0)!
        for minutes in stride(from: 0.0, to: 1440, by: 1) {
            let moment = Self.moment(minutes: minutes, appearance: .dark, rise: pair.riseMinutes, set: pair.setMinutes)
            #expect(moment.twilight.te >= -0.1 - 1e-9 && moment.twilight.te <= 1.1 + 1e-9, "te at \(minutes)")
            if moment.time.night < 1 { #expect(moment.twilight.phase == .day, "phase at \(minutes)") }
        }
    }

    @Test func aDawnBeforeMidnightIsReadOnTheSameAxis() {
        // The mirror (canon, extro 5ed645e420): rise 20, set 1300, dark, 393 × 852 — values
        // from `SUNARC.both()`.
        let rows: [(minutes: Double, phase: SunArcTwilight.Phase, w: Double, t: Double?, night: Double)] = [
            (1425, .beforeDawn, 0.9850, nil, 1),
            (1435, .day, 0.9734, 0.0037, 0.833),
            (0, .day, 0.9467, 0.0075, 0.667),
            (60, .day, 0.6356, 0.0522, 0),
        ]
        for row in rows {
            let moment = Self.moment(minutes: row.minutes, appearance: .dark, rise: 20, set: 1300)
            #expect(moment.twilight.phase == row.phase, "phase at \(row.minutes)")
            #expect(abs(moment.twilight.w - row.w) < 0.0005, "w at \(row.minutes): \(moment.twilight.w)")
            if let t = row.t { #expect(abs(moment.time.t - t) < 0.0005, "t at \(row.minutes): \(moment.time.t)") }
            #expect(abs(moment.time.night - row.night) < 0.001, "night at \(row.minutes): \(moment.time.night)")
        }
    }

    @Test func theDeckKeepsItsTileCreamDayAndTheTablesOtherGrounds() {
        // § 6: another F3 ground may be the light day ground; night, true dark and the whole
        // dark row are the table's.
        let deck = SunArcGroundPalette(lightDayHex: "#FCF3E4")
        let cases: [(minutes: Double, appearance: SunArcAppearance, ground: String)] = [
            (780, .light, "#FCF3E4"), (780, .dark, "#392E26"),
            (60, .light, "#D7C9B0"), (60, .dark, "#281E17"),
            (1181, .dark, "#2E241C"),
        ]
        for c in cases {
            let moment = SunArcBackgroundMoment.at(
                minutes: c.minutes,
                riseMinutes: Self.rise,
                setMinutes: Self.set,
                grounds: deck.grounds(for: c.appearance),
                appearance: c.appearance
            )
            #expect(moment.groundHex == c.ground, "\(c.appearance) at \(c.minutes): \(moment.groundHex)")
            // What the Canvas paints is the moment's own ground — never the ground mixed again.
            #expect(moment.drawing(sceneSize: CGSize(width: 1024, height: 768)).drawing.groundHex == moment.groundHex)
        }
    }
}

/// 🔒 2026-09-23: the appearance is the owner's system setting. The pattern reads it and
/// nothing sets it by clock.
@Suite("SunArc appearance follows the system")
struct SunArcAppearanceFollowsTheSystemTests {
    @Test func theSystemSchemeIsTheAppearance() {
        #expect(SunArcAppearance(ColorScheme.dark) == .dark)
        #expect(SunArcAppearance(ColorScheme.light) == .light)
    }

    @Test func theClockNeverChangesTheAppearance() {
        var calendar = Calendar(identifier: .gregorian)
        let denver = TimeZone(identifier: "America/Denver")!
        calendar.timeZone = denver
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        for minute in stride(from: 0, to: 1440, by: 1) {
            let date = start.addingTimeInterval(Double(minute) * 60)
            for appearance in [SunArcAppearance.light, .dark] {
                let moment = SunArcBackgroundMoment.resolve(
                    date: date,
                    timeZone: denver,
                    palette: SunArcGroundPalette(lightDayHex: "#FCF3E4"),
                    appearance: appearance,
                    presentationCoordinate: nil
                )
                #expect(moment.appearance == appearance)
                #expect((SunArcOKLab.lightness(ofHex: moment.groundHex) < 0.5) == (appearance == .dark))
            }
        }
    }
}

@Suite("SunArc content slices — one root scene")
struct SunArcSceneFrameTests {
    private let localFrame = CGRect(x: 320, y: 0, width: 704, height: 768)
    private let rootFrame = CGRect(x: 0, y: 0, width: 1024, height: 768)

    @Test func rootCanvasUsesItsOwnMeasuredFrame() {
        #expect(SunArcSceneFrame.resolve(viewportFrame: nil, localFrame: self.localFrame) == self.localFrame)
    }

    @Test func contentSliceDrawsGroundOnlyUntilRootViewportExists() {
        #expect(SunArcSceneFrame.resolve(viewportFrame: .zero, localFrame: self.localFrame) == nil)
    }

    @Test func everyContentSliceUsesTheMeasuredRootViewport() {
        #expect(SunArcSceneFrame.resolve(viewportFrame: self.rootFrame, localFrame: self.localFrame) == self.rootFrame)
    }
}

/// § 5's fallback chain and § 12's ninth acceptance item — *"With location denied or absent,
/// the times come from the system timezone's tzdb point, not from a fixed default."* The
/// reference day is the spec's own worked example (§ 4: Denver, 2026-09-19, rise 06:44,
/// set 19:02).
@Suite("SunArc solar — the §5 three-rung chain")
struct SunArcSolarTests {
    static let sept19 = Date(timeIntervalSince1970: 1_789_819_200) // 2026-09-19T12:00:00Z
    static let june21 = Date(timeIntervalSince1970: 1_782_043_200) // 2026-06-21T12:00:00Z
    static let denver = TimeZone(identifier: "America/Denver")!

    @Test func theBundledZoneTableCarriesTheSpecsWorkedPoint() {
        // § 5 rung 2: "America/Denver → 39.74° N, 104.98° W".
        let point = SunArcZonePoints.point(for: "America/Denver")
        #expect(point != nil)
        #expect(abs((point?.latitude ?? 0) - 39.74) < 0.005)
        #expect(abs((point?.longitude ?? 0) - (-104.98)) < 0.005)
        // tzdb 2026c zone.tab, generated by vpx/design-system/tools/gen-sun-arc-zone-points.py
        #expect(SunArcZonePoints.zoneCount == 418)
        #expect(SunArcZonePoints.point(for: "Europe/Oslo") != nil)
        #expect(SunArcZonePoints.point(for: "America/Indiana/Indianapolis") != nil)
    }

    @Test func denverSunriseAndSunsetMatchTheSpecsWorkedDay() {
        // § 4's worked table: rise 06:44, set 19:02 on 2026-09-19.
        let times = SunArcSolar.times(latitude: 39.74, longitude: -104.98, date: Self.sept19, utcOffsetMinutes: -360)
        #expect(times != nil)
        #expect(abs((times?.riseMinutes ?? 0) - Double(6 * 60 + 44)) <= 1.0)
        #expect(abs((times?.setMinutes ?? 0) - Double(19 * 60 + 2)) <= 1.0)
    }

    @Test func theSystemTimezoneIsTheSecondRungNotTheFixedDefault() {
        // § 12: "With location denied or absent, the times come from the system timezone's
        // tzdb point, not from a fixed default."
        let pair = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        #expect(pair != SunArcSolar.fallback)
        #expect(abs(pair.riseMinutes - Double(6 * 60 + 44)) <= 1.0)
        #expect(abs(pair.setMinutes - Double(19 * 60 + 2)) <= 1.0)
    }

    @Test func aLocationTheAppAlreadyHoldsOutranksTheZonePoint() {
        // § 5 rung 1 ahead of rung 2. A host may pass an existing retained location; the
        // ordering is asserted here so that coordinate outranks its timezone reference point.
        let sydney = SunArcSolar.pair(
            for: Self.sept19,
            heldLocation: SunArcCoordinate(latitude: -33.87, longitude: 151.22),
            timeZone: Self.denver
        )
        let zoneOnly = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        #expect(sydney != zoneOnly)
        #expect(sydney != SunArcSolar.fallback)
    }

    @Test func aTimezoneChangeChangesTheTimes() {
        // § 5: "Recompute once a day and on a timezone or location change."
        let tokyo = SunArcSolar.pair(for: Self.sept19, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let denver = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        #expect(tokyo != denver)
        #expect(tokyo != SunArcSolar.fallback)
    }

    @Test func anIdentifierTheTableDoesNotKnowTakesTheFixedDefault() {
        // § 5 rung 3: "06:30 / 19:30 only if the zone identifier is unknown to the table."
        let unknown = TimeZone(secondsFromGMT: 0)!
        #expect(SunArcZonePoints.point(for: unknown.identifier) == nil)
        let pair = SunArcSolar.pair(for: Self.sept19, timeZone: unknown)
        #expect(pair == SunArcSolar.fallback)
        #expect(pair.riseMinutes == 6 * 60 + 30)
        #expect(pair.setMinutes == 19 * 60 + 30)
    }

    @Test func polarDayHoldsTheLastValidPairRatherThanTheFixedDefault() {
        // § 5: "In polar day or night (no sunrise) hold the last valid pair."
        let longyearbyen = TimeZone(identifier: "Arctic/Longyearbyen")!
        let point = SunArcZonePoints.point(for: "Arctic/Longyearbyen")!
        let offset = Double(longyearbyen.secondsFromGMT(for: Self.june21)) / 60

        // The midsummer day itself has no sunrise at 78° N...
        #expect(SunArcSolar.times(latitude: point.latitude, longitude: point.longitude, date: Self.june21, utcOffsetMinutes: offset) == nil)
        // ...and the chain still produces a real pair rather than 06:30/19:30. `setMinutes` may
        // now exceed 1440 (a sunset carried past midnight, § the post-midnight-sunset fix
        // below) — the invariant is a sane, non-negative day length, not an arbitrary ceiling.
        let pair = SunArcSolar.pair(for: Self.june21, timeZone: longyearbyen)
        #expect(pair != SunArcSolar.fallback)
        #expect(pair.riseMinutes >= 0 && pair.riseMinutes < 1440)
        #expect(pair.setMinutes >= pair.riseMinutes)
        #expect(pair.setMinutes - pair.riseMinutes < 1440)
    }

    @Test func dayOfYearUsesTheCivilDateInTheEnginesTimezoneNotUTC() {
        // Two instants six hours apart that cross UTC midnight (Sep 18 → Sep 19) but land on
        // the SAME local calendar day (Sep 18) at UTC-10 (Honolulu-like coordinates, no DST).
        // Before the fix, `times()` derived its day-of-year from the UTC calendar day, so these
        // two calls would silently use different days (Sep 18 vs Sep 19) and disagree.
        let lat = 21.3069, lon = -157.8583, offset = -600.0
        let beforeUTCMidnight = Date(timeIntervalSince1970: 1_789_761_600) // 2026-09-18T20:00:00Z (local: Sep 18, 10:00)
        let afterUTCMidnight = Date(timeIntervalSince1970: 1_789_783_200) // 2026-09-19T02:00:00Z (local: Sep 18, 16:00)

        let a = SunArcSolar.times(latitude: lat, longitude: lon, date: beforeUTCMidnight, utcOffsetMinutes: offset)
        let b = SunArcSolar.times(latitude: lat, longitude: lon, date: afterUTCMidnight, utcOffsetMinutes: offset)
        #expect(a != nil && b != nil)
        #expect(a == b)
    }

    @Test func reykjavikMidsummerSunsetAfterMidnightKeepsDayProgressForwardAcrossMidnight() {
        // § the post-midnight-sunset fix: above ~64° in midsummer the sun sets after local
        // midnight (Reykjavik, 21 June: rise ≈ 02:54, raw wrapped set ≈ 00:03 — a smaller
        // number than rise). Uncorrected, `dusk` (set + twilight) falls before `dawn`
        // (rise − twilight), so `SunArcTime.compute`'s day fraction has a negative-length
        // denominator and reads almost the entire day as night. Corrected, the day runs
        // rise → (next-day) dusk without inverting, and progress never runs backward across
        // the midnight boundary.
        let reykjavik = (latitude: 64.1466, longitude: -21.9426)
        let offset = 0.0 // Iceland observes no daylight saving

        let pair = SunArcSolar.times(latitude: reykjavik.latitude, longitude: reykjavik.longitude, date: Self.june21, utcOffsetMinutes: offset)
        #expect(pair != nil)
        guard let pair else { return }
        #expect(abs(pair.riseMinutes - Double(2 * 60 + 55)) < 2) // ≈ 02:54
        #expect(pair.setMinutes > 1440) // carried onto the next day, not wrapped back to ≈00:03
        #expect(abs(pair.setMinutes - 1440 - Double(0 * 60 + 4)) < 2) // ≈ 00:03/00:04 the next day

        // Midday must read as day, not the "almost the whole day is night" symptom of the bug.
        let midday = SunArcTime.compute(minutes: 12 * 60, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        #expect(midday.night == 0)

        // Day progress across the midnight boundary is continuous and strictly forward, never
        // resetting or running backward: 23:59 is still day (before the ≈00:04 sunset), local
        // midnight (00:00) is still day too, and 00:10 — comfortably inside the 30-minute dusk
        // twilight that follows the true sunset instant — has started ramping into night.
        let justBeforeMidnight = SunArcTime.compute(minutes: 1439, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        let atMidnight = SunArcTime.compute(minutes: 0, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        let intoDuskTwilight = SunArcTime.compute(minutes: 10, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        #expect(justBeforeMidnight.night == 0)
        #expect(atMidnight.night == 0)
        #expect(justBeforeMidnight.t < atMidnight.t)
        #expect(atMidnight.t < intoDuskTwilight.t)
        #expect(intoDuskTwilight.night > 0 && intoDuskTwilight.night < 1)
    }

    @Test func polarLookbackRecomputesTheOffsetPerProbeDateAcrossADSTBoundary() {
        // § the polar-lookback offset fix: a lookback that spans a daylight-saving boundary
        // must use each probed date's own offset. `heldLocation` pushes the polar-night
        // threshold to early October at 85° N (real Longyearbyen, 78° N, would not need to
        // look back far enough to cross the boundary); `Arctic/Longyearbyen`'s real DST rule
        // supplies the offset. Starting 2026-11-01 (CET, UTC+1) and walking back finds
        // 2026-10-07 (CEST, UTC+2) as the last day with a real sunrise — 25 days back, crossing
        // the 2026-10-25 DST end. A single stale offset reused for every probe would apply
        // Nov 1's CET offset to Oct 7, skewing the result by a full hour.
        let longyearbyen = TimeZone(identifier: "Arctic/Longyearbyen")!
        let start = Date(timeIntervalSince1970: 1_793_534_400) // 2026-11-01T12:00:00Z
        let pole = SunArcCoordinate(latitude: 85.0, longitude: 15.6267)

        let pair = SunArcSolar.pair(for: start, heldLocation: pole, timeZone: longyearbyen)
        #expect(pair != SunArcSolar.fallback)

        let oct7 = Date(timeIntervalSince1970: 1_793_534_400 - 25 * 86_400) // 2026-10-07T12:00:00Z
        let correctOffset = Double(longyearbyen.secondsFromGMT(for: oct7)) / 60
        #expect(correctOffset == 120) // CEST — still before the Oct 25 DST end

        let expected = SunArcSolar.times(latitude: pole.latitude, longitude: pole.longitude, date: oct7, utcOffsetMinutes: correctOffset)
        #expect(expected != nil)
        guard let expected else { return }
        #expect(pair == expected)

        // The bug this guards against: reusing Nov 1's CET (UTC+1) offset for the Oct 7 probe
        // would have skewed both times by exactly one hour.
        let staleOffset = Double(longyearbyen.secondsFromGMT(for: start)) / 60
        #expect(staleOffset == 60) // CET
        let stale = SunArcSolar.times(latitude: pole.latitude, longitude: pole.longitude, date: oct7, utcOffsetMinutes: staleOffset)
        #expect(stale != nil)
        guard let stale else { return }
        #expect(abs(pair.riseMinutes - stale.riseMinutes - 60) < 0.01)
    }

    @Test func theBackgroundDrawsFromTheChainNotFromTheFixedDefault() {
        // The view's own clock now moves with the zone: the same instant in two zones puts the
        // sun at two different points on its arc.
        let denverPair = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        let tokyoPair = SunArcSolar.pair(for: Self.sept19, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let denverTime = SunArcTime.compute(minutes: 12 * 60, riseMinutes: denverPair.riseMinutes, setMinutes: denverPair.setMinutes)
        let tokyoTime = SunArcTime.compute(minutes: 12 * 60, riseMinutes: tokyoPair.riseMinutes, setMinutes: tokyoPair.setMinutes)
        #expect(abs(denverTime.t - tokyoTime.t) > 0.001)
    }
}
