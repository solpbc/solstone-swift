// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

nonisolated struct WatchHomeControlStyle: Equatable, Sendable {
    static let minHeight: CGFloat = 44
    var label: String
    var fillHex: String?
    var labelHex: String
    var labelAlpha: Double
    var strokeHex: String?
    var strokeAlpha: Double
    var strokeLineWidth: CGFloat
}

/// The single pinned control. It only draws on the active face (on ink); the wrist-down face
/// shows the sun arc alone.
nonisolated func watchHomeControlStyle(isRunning: Bool) -> WatchHomeControlStyle {
    let label = isRunning ? "stop" : "start"
    let labelHex = isRunning ? WatchHomePalette.cream : SunArc.inkHex

    if isRunning {
        return WatchHomeControlStyle(
            label: label,
            fillHex: "#3A3632",
            labelHex: labelHex,
            labelAlpha: 1,
            strokeHex: nil,
            strokeAlpha: 0,
            strokeLineWidth: 0
        )
    } else {
        return WatchHomeControlStyle(
            label: label,
            fillHex: SunArc.orangeHex,
            labelHex: labelHex,
            labelAlpha: 1,
            strokeHex: nil,
            strokeAlpha: 0,
            strokeLineWidth: 0
        )
    }
}
