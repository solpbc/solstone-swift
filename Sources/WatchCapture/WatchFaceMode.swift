// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The watch face is bi-modal (founder, 2026-09-23): "low-power positional sun mark in reduced
/// luminance … or visible control/text with no contrast issue." The mode is
/// `isLuminanceReduced` and nothing else: a notification or Control Center over a raised wrist
/// is still the active face.
nonisolated enum WatchFaceMode: Equatable, Sendable {
    /// Wrist up: the hero, the details and the control on brand ink. No sun arc.
    case active
    /// Wrist down / Always On: only the sun arc's dark row, over black. No content.
    case reduced

    init(luminanceReduced: Bool) {
        self = luminanceReduced ? .reduced : .active
    }

    var showsSunArc: Bool { self == .reduced }
    var showsContent: Bool { self == .active }
    var groundHex: String { self == .reduced ? "#000000" : WatchHomePalette.ground }
}
