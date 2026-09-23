// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// One radial glow — §7. Stops `a → 0.45a → 0` at 0 / 38 / 100 % of `radius`.
nonisolated struct SunArcGlowLayer: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The day halo: gold, φR, on the sun.
        case halo
        /// The twilight glow: φ²R, on the hidden sun's extended path.
        case twilight
    }

    var kind: Kind
    var center: CGPoint
    var radius: Double
    var alpha: Double
    var colorHex: String
}

/// Everything one frame draws, in the scene's own coordinates. Layer order: ground, then
/// `glows` in array order (halo, then twilight — the order `SUNARC.both()` composites them),
/// then the sun.
nonisolated struct SunArcCanvasDrawing: Equatable, Sendable {
    var groundHex: String
    var glows: [SunArcGlowLayer]
    var beamHex: String
    var ringHex: String
    var sunOpacity: Double
    var drawSun: Bool

    func glow(_ kind: SunArcGlowLayer.Kind) -> SunArcGlowLayer? {
        self.glows.first { $0.kind == kind }
    }
}

/// `SUNARC.both()` for one frame (spec §§ 4a, 6, 7, 8a), plus the watch's standing 09-22 power
/// rule: `luminanceReduced` (wrist down) draws black with the sun off and every glow capped at
/// `SunArc.wristDownGlowCap`. The day halo follows the time on every surface, the watch
/// included (founder, 2026-09-23: the capture gate is dropped; the hero carries the state).
nonisolated func sunArcCanvasDrawing(
    time: SunArcTime,
    envelope: Double,
    twilight: SunArcTwilight,
    placement: SunArcPlacement,
    grounds: SunArcGrounds,
    appearance: SunArcAppearance,
    luminanceReduced: Bool = false
) -> SunArcCanvasDrawing {
    let isDark = appearance == .dark
    let onVisible = time.t > -0.02 && time.t < 1.02
    let sunPosition = placement.position(at: min(1, max(0, time.t)))
    let ground = SunArcGround.current(grounds: grounds, night: time.night, twilightWeight: twilight.w)

    var glows: [SunArcGlowLayer] = []
    if time.night < 1, onVisible {
        glows.append(SunArcGlowLayer(
            kind: .halo,
            center: sunPosition,
            radius: SunArc.phi * placement.tipRadius,
            alpha: SunArc.glowDayAlpha * envelope * (1 - time.night),
            colorHex: SunArc.goldHex
        ))
    }
    if twilight.w > 0.001 {
        let colorHex = isDark
            ? SunArcOKLab.mix(SunArc.goldHex, SunArc.orangeHex, 0.30 + 0.50 * twilight.x)
            : SunArcOKLab.mix(SunArc.sunriseCreamHex, SunArc.goldHex, 0.45 + 0.25 * twilight.x)
        glows.append(SunArcGlowLayer(
            kind: .twilight,
            center: placement.position(at: twilight.te),
            radius: SunArc.twilightRadiusRatio * placement.tipRadius,
            alpha: (isDark ? SunArc.twilightAlphaDark : SunArc.twilightAlphaLight) * twilight.w,
            colorHex: colorHex
        ))
    }

    var sunOpacity = 0.0
    if onVisible {
        let peak = isDark ? SunArc.peakOpacityDark : SunArc.peakOpacityLight
        sunOpacity = peak * envelope * (1 - time.night)
        if time.t <= 0 || time.t >= 1 { sunOpacity *= (1 - time.night) }
    }

    if luminanceReduced {
        for index in glows.indices {
            glows[index].alpha = min(glows[index].alpha, SunArc.wristDownGlowCap)
        }
        sunOpacity = 0
    }

    return SunArcCanvasDrawing(
        groundHex: luminanceReduced ? "#000000" : ground,
        glows: glows,
        beamHex: SunArc.goldHex,
        ringHex: SunArc.orangeHex,
        sunOpacity: sunOpacity,
        drawSun: !luminanceReduced && sunOpacity > 0.001
    )
}
