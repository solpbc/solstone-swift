// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// The sun, all day — time-of-day background pattern.
///
/// Ported from `cmo/brand/sbis/patterns/sun-arc/{index.md,sunarc.js}` in the extro repo
/// (founder lock 2026-09-19, amended 2026-09-23: the day in both appearances). Vendor the
/// reference math; do not re-derive it from the token constants alone. Section numbers below
/// (§3, §4, §4a, §6, §7, §8a) refer to that spec; the 09-23 model is `SUNARC.both()`.
public nonisolated enum SunArc {
    public static let phi: Double = 1.618_033_988_7
    public static let bow: Double = 0.079_19               // sagitta ÷ chord, §3
    public static let peakOpacityLight: Double = 0.55       // §2 on a light ground
    public static let peakOpacityDark: Double = 0.20        // §8a on a dark ground — the same OKLab step
    public static let envelopeEdge: Double = 0.22           // §4 rise·hold·set
    public static let twilightMinutes: Double = 30
    public static let glowDayAlpha: Double = 0.22           // §7 the day halo, × env × (1 − night)
    public static let twilightRadiusRatio: Double = phi * phi // §7 the twilight glow's radius, × R
    public static let twilightAlphaDark: Double = 0.62      // §7 × w
    public static let twilightAlphaLight: Double = 0.95     // §7 × w
    public static let twilightSink: Double = 0.10           // §4a the hidden sun runs to t ∈ [−0.10, 1.10]
    public static let trueDarkMinutes: Double = 180         // §4a centred on solar midnight
    public static let gradientMidStop: Double = 0.38
    public static let gradientMidRatio: Double = 0.45

    public static let inkHex = "#1A1A1A"
    public static let goldHex = "#FFCC33"
    public static let orangeHex = "#E8913A"
    public static let surfaceCreamHex = "#FEFCF8"
    /// The sunrise gradient's cream-gold (ruled 2026-07-03) — the light twilight glow's cool end.
    public static let sunriseCreamHex = "#FFF3CF"

    /// §5 rung 3, last resort — only for a zone identifier the bundled tzdb table does not
    /// know. Rungs 1 and 2 are `SunArcSolar.pair(for:)`.
    public static let fallbackRiseMinutes: Double = 6 * 60 + 30
    public static let fallbackSetMinutes: Double = 19 * 60 + 30
}

/// The owner's light or dark setting — §6. The pattern reads it; ⛔ it never sets it.
public nonisolated enum SunArcAppearance: Sendable, Equatable {
    case light
    case dark
}

/// One appearance's three grounds — §6.
public nonisolated struct SunArcGrounds: Sendable, Equatable {
    public let day: String
    public let night: String
    public let deep: String

    public init(day: String, night: String, deep: String) {
        self.day = day
        self.night = night
        self.deep = deep
    }

    /// Light: surface cream · cream toward tone · tone toward the warm dark.
    public static let light = SunArcGrounds(day: "#FEFCF8", night: "#E9DECC", deep: "#D7C9B0")
    /// Dark: the lifted warm dark · the 09-19 night ground · true dark. The watch always uses these.
    public static let dark = SunArcGrounds(day: "#392E26", night: "#2E241C", deep: "#281E17")

    /// §6: "A surface whose own ground is another F3 ground (tile cream, white) uses it as its
    /// light day ground and keeps the table's night and true dark."
    public static func light(day: String) -> SunArcGrounds {
        SunArcGrounds(day: day, night: Self.light.night, deep: Self.light.deep)
    }
}

/// A location a host already holds for its own purpose — §5 rung 1.
///
/// The engine never obtains this value itself. Keeping this Sendable value separate from
/// platform location types preserves the engine's permission- and framework-free boundary.
public nonisolated struct SunArcCoordinate: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// §5 — sunrise and sunset, on the device, never off it. The standard sunrise equation
/// (NOAA / *Almanac for Computers*, official zenith 90.833°) run against coordinates found
/// by the spec's three rungs:
///
/// 1. a location the app already holds for its own reasons — a host may pass it here, but ⛔
///    this engine never asks for one for this pattern alone;
/// 2. the system timezone's tzdb reference point (`SunArcZonePoints`, bundled with the build);
/// 3. 06:30 / 19:30 for a zone identifier the table does not know.
///
/// Nothing here reads the network or the device's location.
public nonisolated enum SunArcSolar {
    public nonisolated struct Pair: Sendable, Equatable {
        public let riseMinutes: Double
        public let setMinutes: Double
        public init(riseMinutes: Double, setMinutes: Double) {
            self.riseMinutes = riseMinutes
            self.setMinutes = setMinutes
        }
    }

    /// §5 rung 3.
    public static let fallback = Pair(riseMinutes: SunArc.fallbackRiseMinutes, setMinutes: SunArc.fallbackSetMinutes)

    /// How far back `pair(for:)` will look for the last day that had a sunrise, in the polar
    /// case — half a year always reaches one.
    static let polarLookbackDays = 183

    /// Sunrise and sunset as local minutes since midnight, or `nil` in polar day or night
    /// (the sun never crosses the horizon that day).
    public static func times(
        latitude: Double,
        longitude: Double,
        date: Date,
        utcOffsetMinutes: Double
    ) -> Pair? {
        let n = Double(civilDayOfYear(date, utcOffsetMinutes: utcOffsetMinutes))
        let lngHour = longitude / 15

        func solar(_ isRise: Bool) -> Double? {
            let t = n + ((isRise ? 6.0 : 18.0) - lngHour) / 24
            let meanAnomaly = 0.9856 * t - 3.289
            let mRad = meanAnomaly * .pi / 180
            let trueLongitude = wrap(meanAnomaly + 1.916 * sin(mRad) + 0.020 * sin(2 * mRad) + 282.634, 360)
            let lRad = trueLongitude * .pi / 180

            var rightAscension = wrap(atan(0.91764 * tan(lRad)) * 180 / .pi, 360)
            let lQuadrant = (trueLongitude / 90).rounded(.down) * 90
            let raQuadrant = (rightAscension / 90).rounded(.down) * 90
            rightAscension = (rightAscension + (lQuadrant - raQuadrant)) / 15

            let sinDec = 0.39782 * sin(lRad)
            let cosDec = cos(asin(sinDec))
            let latRad = latitude * .pi / 180
            let cosH = (cos(90.833 * .pi / 180) - sinDec * sin(latRad)) / (cosDec * cos(latRad))
            guard cosH <= 1, cosH >= -1 else { return nil }

            let acosDeg = acos(cosH) * 180 / .pi
            let hourAngle = (isRise ? 360 - acosDeg : acosDeg) / 15
            let localMeanTime = hourAngle + rightAscension - 0.06571 * t - 6.622
            let ut = wrap(localMeanTime - lngHour, 24)
            return wrap(ut * 60 + utcOffsetMinutes, 1440)
        }

        guard let rise = solar(true), let rawSet = solar(false) else { return nil }
        // Rise and set are wrapped independently into 0...1440. Above ~64° in midsummer the
        // sun sets after local midnight, so the raw set can land numerically before rise —
        // carry it onto the next day so the day's own dawn-to-dusk axis stays continuous
        // (`SunArcTime.compute` reads minutes on this same extended axis).
        let set = rawSet < rise ? rawSet + 1440 : rawSet
        return Pair(riseMinutes: rise, setMinutes: set)
    }

    /// The pair to draw today's arc from, walking the §5 rungs in order.
    ///
    /// In polar day or night the spec says to hold the last valid pair; this finds it by
    /// walking back to the most recent day that has one, so a cold launch inside the polar
    /// night behaves exactly like a session that ran through the polar sunset.
    public static func pair(
        for date: Date,
        heldLocation: SunArcCoordinate? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Pair {
        let heldCoordinates = heldLocation.map { (latitude: $0.latitude, longitude: $0.longitude) }
        guard let coords = heldCoordinates ?? SunArcZonePoints.point(for: timeZone.identifier) else {
            return fallback
        }
        var probe = date
        for _ in 0...polarLookbackDays {
            // Recompute the offset for every probed date, not once for `date` — a lookback
            // that spans a daylight-saving boundary must use each day's own offset, or a
            // probe on the far side of the boundary is skewed by an hour.
            let offset = Double(timeZone.secondsFromGMT(for: probe)) / 60
            if let found = times(latitude: coords.latitude, longitude: coords.longitude, date: probe, utcOffsetMinutes: offset) {
                return found
            }
            probe = probe.addingTimeInterval(-86_400)
        }
        return fallback
    }

    private static func wrap(_ v: Double, _ modulus: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: modulus)
        return r < 0 ? r + modulus : r
    }

    /// The ordinal day of the passed timezone's civil date — not the UTC date, which can be a
    /// different calendar day near midnight for any offset that isn't ~0. `utcOffsetMinutes`
    /// (already resolved by the caller for this instant) is enough to build that civil
    /// calendar directly, without needing the zone's IANA identifier here.
    private static func civilDayOfYear(_ date: Date, utcOffsetMinutes: Double) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: Int(utcOffsetMinutes * 60)) ?? .gmt
        return calendar.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

/// §3 — the sun's position on its 36° arc between the dawn corner (top-left) and the dusk
/// corner (bottom-right), for a surface of a given size and the sun's tip radius `R`.
public nonisolated struct SunArcPlacement: Sendable {
    public let a: CGPoint
    public let b: CGPoint
    public let chord: Double
    public let sagitta: Double
    public let arcRadius: Double
    public let center: CGPoint
    /// R, the sun's tip radius — the unit of both glow radii (φR, φ²R).
    public let tipRadius: Double
    private let thetaA: Double
    private let delta: Double

    public init(size: CGSize, tipRadius: Double) {
        let w = Double(size.width), h = Double(size.height)
        self.tipRadius = tipRadius
        let k = tipRadius / 2.0.squareRoot()
        let a = CGPoint(x: -k, y: -k)
        let b = CGPoint(x: w + k, y: h + k)
        self.a = a
        self.b = b

        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let c = (dx * dx + dy * dy).squareRoot()
        self.chord = c
        let ux = dx / c, uy = dy / c
        let mx = (Double(a.x) + Double(b.x)) / 2, my = (Double(a.y) + Double(b.y)) / 2

        let s = SunArc.bow * c
        self.sagitta = s
        // the normal to the chord whose y-component is negative — toward the top of the frame.
        var nx = -uy, ny = ux
        if ny > 0 { nx = -nx; ny = -ny }

        let rarc = c * c / (8 * s) + s / 2
        self.arcRadius = rarc
        let ox = mx - nx * (rarc - s), oy = my - ny * (rarc - s)
        let center = CGPoint(x: ox, y: oy)
        self.center = center

        self.thetaA = atan2(Double(a.y) - oy, Double(a.x) - ox)
        let thetaB = atan2(Double(b.y) - oy, Double(b.x) - ox)
        var d = thetaB - thetaA
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        self.delta = d
    }

    /// The sun's centre at time `t` (unclamped — the caller decides visibility at t < 0 / t > 1;
    /// §4a's hidden sun reads it at t ∈ [−0.10, 1.10]).
    public func position(at t: Double) -> CGPoint {
        let theta = thetaA + delta * t
        return CGPoint(x: center.x + arcRadius * cos(theta), y: center.y + arcRadius * sin(theta))
    }
}

/// §4 — the day's own clock: dawn/dusk, the arc parameter `t`, and night (0…1).
public nonisolated struct SunArcTime: Sendable, Equatable {
    public let t: Double
    public let night: Double
    /// The minute on the day's own axis: this calendar day's minutes, carried past 1440 when
    /// the sunset itself was (see `compute`). `SunArcTwilight` reads the same axis.
    public let minutes: Double
    public let riseMinutes: Double
    public let setMinutes: Double

    public init(t: Double, night: Double, minutes: Double, riseMinutes: Double, setMinutes: Double) {
        self.t = t
        self.night = night
        self.minutes = minutes
        self.riseMinutes = riseMinutes
        self.setMinutes = setMinutes
    }

    /// Local minute quantization used by the once-per-minute rendering host.
    public static func minutesSinceMidnight(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Double {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    public static func compute(
        minutes m: Double,
        riseMinutes rise: Double,
        setMinutes rawSet: Double,
        twilightMinutes tw: Double = SunArc.twilightMinutes
    ) -> SunArcTime {
        // One extended minute axis (spec §4a, 2026-09-23): a sunset after local midnight that
        // arrives wrapped below sunrise is carried past 1440. `SunArcSolar.times` already
        // carries it; this keeps any other caller on the same axis.
        let set = rawSet < rise ? rawSet + 1440 : rawSet
        let dawn = rise - tw, dusk = set + tw

        // `set` (and so `dusk`) may already have been carried past 1440 by `SunArcSolar.times`
        // when the sun sets after local midnight. `m` is always given as this calendar day's
        // own minutes-since-midnight, so a small `m` that falls before the wrapped-back dusk
        // is really the tail of tonight's dusk, not tomorrow's pre-dawn night — read it on the
        // same extended axis dusk is already on, so day progress keeps moving forward through
        // midnight instead of resetting to "before dawn".
        //
        // The mirror: a sunrise before 00:30 puts dawn before midnight, so the last clock
        // minutes of the day are tomorrow's dawn, read on the same axis (canon, extro 5ed645e420).
        let m2: Double
        if dusk > 1440 && m < dusk - 1440 { m2 = m + 1440 }
        else if dawn < 0 && m >= dawn + 1440 { m2 = m - 1440 }
        else { m2 = m }

        let t = (m2 - dawn) / (dusk - dawn)

        let night: Double
        if m2 < dawn { night = 1 }
        else if m2 < rise { night = 1 - (m2 - dawn) / tw }
        else if m2 <= set { night = 0 }
        else if m2 < dusk { night = (m2 - set) / tw }
        else { night = 1 }

        return SunArcTime(t: t, night: night, minutes: m2, riseMinutes: rise, setMinutes: set)
    }
}

/// §4 — brightness envelope: sine rise, full hold, sine set, over the first/last `edge` of the path.
public nonisolated enum SunArcEnvelope {
    public static func value(at t: Double, edge: Double = SunArc.envelopeEdge) -> Double {
        let u = min(1, max(0, t))
        if u < edge { return sin(u / edge * .pi / 2) }
        if u > 1 - edge { return sin((1 - u) / edge * .pi / 2) }
        return 1
    }
}

/// §6 — OKLab colour mixing (Björn Ottosson's OKLab). `Color.mix` on Apple platforms blends in
/// sRGB, which is not what the spec's ground formula calls for.
public nonisolated enum SunArcOKLab {
    public nonisolated struct RGB: Sendable { public let r: Double; public let g: Double; public let b: Double }

    public static func rgb(fromHex hex: String) -> RGB {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    public static func hex(fromRGB rgb: RGB) -> String {
        func byte(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(rgb.r), byte(rgb.g), byte(rgb.b))
    }

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.003_130_8 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
    }

    private static func toOKLab(_ rgb: RGB) -> (l: Double, a: Double, b: Double) {
        let r = srgbToLinear(rgb.r), g = srgbToLinear(rgb.g), b = srgbToLinear(rgb.b)
        let l = 0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b
        let m = 0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b
        let s = 0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (
            0.210_454_255_3 * l_ + 0.793_617_785_0 * m_ - 0.004_072_046_8 * s_,
            1.977_998_495_1 * l_ - 2.428_592_205_0 * m_ + 0.450_593_709_9 * s_,
            0.025_904_037_1 * l_ + 0.782_771_766_2 * m_ - 0.808_675_766_0 * s_
        )
    }

    private static func fromOKLab(_ lab: (l: Double, a: Double, b: Double)) -> RGB {
        let l_ = lab.l + 0.396_337_777_4 * lab.a + 0.215_803_757_3 * lab.b
        let m_ = lab.l - 0.105_561_345_8 * lab.a - 0.063_854_172_8 * lab.b
        let s_ = lab.l - 0.089_484_177_5 * lab.a - 1.291_485_548_0 * lab.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s
        let g = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s
        let b = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s
        return RGB(r: linearToSrgb(r), g: linearToSrgb(g), b: linearToSrgb(b))
    }

    /// Mix two hex colours in OKLab, `t` fraction of the way from `hex1` to `hex2`.
    public static func mix(_ hex1: String, _ hex2: String, _ t: Double) -> String {
        if t <= 0 { return hex1 }
        if t >= 1 { return hex2 }
        let a = toOKLab(rgb(fromHex: hex1)), b = toOKLab(rgb(fromHex: hex2))
        let lab = (a.l + (b.l - a.l) * t, a.a + (b.a - a.a) * t, a.b + (b.b - a.b) * t)
        return hex(fromRGB: fromOKLab(lab))
    }

    /// OKLab lightness of a hex colour. §6: every light ground sits above L 0.5 and every dark
    /// ground below it, which is why content never flips.
    public static func lightness(ofHex hex: String) -> Double {
        toOKLab(rgb(fromHex: hex)).l
    }
}

/// §6 — the ground showing right now, in the owner's appearance.
public nonisolated enum SunArcGround {
    /// Day → night across each twilight window by `night`; night → true dark by `1 − w`, so
    /// the ground deepens exactly as the corner's light goes out (§4a). Both mixes in OKLab.
    public static func current(grounds: SunArcGrounds, night: Double, twilightWeight w: Double) -> String {
        let dayToNight = SunArcOKLab.mix(grounds.day, grounds.night, night)
        return SunArcOKLab.mix(dayToNight, grounds.deep, night * (1 - w))
    }
}

/// §4a — the twilight weight `w`, the hidden sun's extended parameter `te`, and how far into
/// the evening (or before the dawn) we are, `x`. A line-for-line port of `A.twilight` and
/// `A.deepWindow` in `sunarc.js`.
public nonisolated struct SunArcTwilight: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case day
        case evening
        case trueDark
        case beforeDawn
    }

    public let w: Double
    public let te: Double
    public let x: Double
    public let phase: Phase

    public init(w: Double, te: Double, x: Double, phase: Phase) {
        self.w = w
        self.te = te
        self.x = x
        self.phase = phase
    }

    /// Holds, then eases to 0 at the edge of the true-dark window.
    static func ease(_ x: Double) -> Double {
        let c = max(0, min(1, x))
        return pow(1 - c * c, 1.5)
    }

    public static func compute(
        time: SunArcTime,
        envelope: Double,
        trueDarkMinutes: Double = SunArc.trueDarkMinutes,
        sink: Double = SunArc.twilightSink,
        twilightMinutes tw: Double = SunArc.twilightMinutes
    ) -> SunArcTwilight {
        let dawn = time.riseMinutes - tw, dusk = time.setMinutes + tw
        let m = time.minutes
        if m >= dawn && m <= dusk {
            return SunArcTwilight(w: 1 - envelope, te: time.t, x: 0, phase: .day)
        }
        let span = wrap(dawn - dusk)
        let ms = wrap(m - dusk)
        let mid = span / 2
        let half = Self.trueDarkHalf(nightSpan: span, trueDarkMinutes: trueDarkMinutes)
        let deepStart = mid - half, deepEnd = mid + half
        if ms <= deepStart && deepStart > 0 {
            let x = ms / deepStart
            return SunArcTwilight(w: ease(x), te: 1 + sink * x, x: x, phase: .evening)
        }
        if ms >= deepEnd && span > deepEnd {
            let x = (span - ms) / (span - deepEnd)
            return SunArcTwilight(w: ease(x), te: -sink * x, x: x, phase: .beforeDawn)
        }
        return SunArcTwilight(w: 0, te: ms < mid ? 1 + sink : -sink, x: 1, phase: .trueDark)
    }

    /// Half the true-dark window for a night of `nightSpan` minutes (dusk to the next dawn):
    /// up to `trueDarkMinutes`, but the glow always keeps at least an hour to ease out and an
    /// hour to ease in, so a short night gets a shorter true dark and a white night none
    /// (`A.deepHalf`).
    static func trueDarkHalf(nightSpan: Double, trueDarkMinutes: Double) -> Double {
        max(0, min(trueDarkMinutes, nightSpan - 120)) / 2
    }

    /// §4a — the true-dark window, in local minutes (each wrapped into 0..<1440).
    public static func trueDarkWindow(
        riseMinutes: Double,
        setMinutes: Double,
        trueDarkMinutes: Double = SunArc.trueDarkMinutes,
        twilightMinutes tw: Double = SunArc.twilightMinutes
    ) -> (from: Double, mid: Double, to: Double) {
        let set = setMinutes < riseMinutes ? setMinutes + 1440 : setMinutes
        let dusk = set + tw, dawn = riseMinutes - tw
        let span = wrap(dawn - dusk)
        let mid = dusk + span / 2
        let half = Self.trueDarkHalf(nightSpan: span, trueDarkMinutes: trueDarkMinutes)
        return (wrap(mid - half), wrap(mid), wrap(mid + half))
    }

    private static func wrap(_ v: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: 1440)
        return r < 0 ? r + 1440 : r
    }
}
