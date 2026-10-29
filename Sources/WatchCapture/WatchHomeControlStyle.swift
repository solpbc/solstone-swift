// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

nonisolated struct WatchHomeControlStyle: Equatable, Sendable {
    static let minHeight: CGFloat = 44
    var label: String
    var labelHex: String
    /// Set for the prominent glass control (start, tinted orange); nil for plain glass (stop).
    var tintHex: String?
}

/// The single pinned control, drawn by the system's glass button styles. It only shows on the
/// active face; the wrist-down face shows the sun arc alone.
nonisolated func watchHomeControlStyle(isRunning: Bool) -> WatchHomeControlStyle {
    if isRunning {
        return WatchHomeControlStyle(label: "stop", labelHex: WatchHomePalette.cream, tintHex: nil)
    } else {
        return WatchHomeControlStyle(label: "start", labelHex: SunArc.inkHex, tintHex: SunArc.orangeHex)
    }
}
