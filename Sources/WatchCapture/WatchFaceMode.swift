// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The sun arc is the watch's background at all times. The mode is `isLuminanceReduced` and
/// nothing else: a notification or Control Center over a raised wrist is still the active face.
nonisolated enum WatchFaceMode: Equatable, Sendable {
    /// Wrist up: the dark sun arc, with the controls and details on their underlays above it.
    case active
    /// Wrist down / Always On: the sun arc over black, and nothing else.
    case reduced

    init(luminanceReduced: Bool) {
        self = luminanceReduced ? .reduced : .active
    }

    var showsContent: Bool { self == .active }
    /// Wrist down paints the sun arc over pure black, with the brighter wrist-down sun.
    var blackGround: Bool { self == .reduced }
}
