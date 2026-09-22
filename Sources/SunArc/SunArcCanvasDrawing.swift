// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

nonisolated struct SunArcCanvasDrawing: Equatable, Sendable {
    var groundHex: String
    var glowPosition: CGPoint
    var glowAlpha: Double
    var beamHex: String
    var ringHex: String
    var sunOpacity: Double
    var drawSun: Bool
}

nonisolated func sunArcCanvasDrawing(
    time: SunArcTime,
    envelope: Double,
    sunPosition: CGPoint,
    placement: SunArcPlacement,
    dayGroundHex: String,
    tonalSun: Bool = false,
    gateDayGlow: Bool = false,
    captureIsActive: Bool = false,
    luminanceReduced: Bool = false
) -> SunArcCanvasDrawing {
    let onVisible = time.t > -0.02 && time.t < 1.02
    let ungatedGround = SunArcGround.currentGround(dayGroundHex: dayGroundHex, night: time.night)
    let groundHex = luminanceReduced ? "#000000" : ungatedGround

    let rawGlow = SunArcGlow.compute(
        time: time,
        sunPosition: sunPosition,
        envelope: envelope,
        onVisible: onVisible,
        placement: placement
    )

    var glowPosition: CGPoint
    var glowAlpha: Double

    if gateDayGlow && time.night < 1 && onVisible {
        glowPosition = sunPosition
        if captureIsActive {
            glowAlpha = SunArc.glowDayAlpha * envelope * (1 - time.night)
        } else {
            glowAlpha = 0
        }
    } else {
        glowPosition = rawGlow.position
        glowAlpha = rawGlow.alpha
    }

    if luminanceReduced {
        glowAlpha = min(glowAlpha, SunArc.glowNightFloor)
    }

    let beamHex: String
    let ringHex: String
    var sunOpacity: Double

    if tonalSun {
        let tonalHex = SunArcOKLab.mix(ungatedGround, "#FCF3E4", 0.09)
        beamHex = tonalHex
        ringHex = tonalHex
        sunOpacity = onVisible ? (envelope * (1 - time.night)) : 0
    } else {
        beamHex = SunArc.goldHex
        ringHex = SunArc.orangeHex
        sunOpacity = onVisible ? (SunArc.peakOpacity * envelope * (1 - time.night)) : 0
    }

    let drawSun = !luminanceReduced && sunOpacity > 0.001
    if luminanceReduced {
        sunOpacity = 0
    }

    return SunArcCanvasDrawing(
        groundHex: groundHex,
        glowPosition: glowPosition,
        glowAlpha: glowAlpha,
        beamHex: beamHex,
        ringHex: ringHex,
        sunOpacity: sunOpacity,
        drawSun: drawSun
    )
}
