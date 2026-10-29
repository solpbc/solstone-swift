// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchHomePalette {
    /// The active face's text sits on underlays (the panel, the error pill, the control) over the
    /// dark sun arc (2026-10-29). Each role is the least-pale tint of its hue that clears 4.5:1
    /// over the brightest background the sun arc puts under watch text, the 2026-09-23 passing
    /// tints, so the text holds even where an underlay is translucent.
    static let cream = "#F4EEE4"
    static let calm = "#D9D9E1"
    static let liveText = "#FED0A7"
    static let inFlight = "#FFD19E"
    static let alert = "#FECEC7"
    /// The error pill's dot: the alert hue at full strength, beside the alert text.
    static let alertDot = "#FF6B5E"
    /// The underlays' opaque fill under Reduce Transparency: the sun arc's dark night ground.
    static let underlayOpaque = "#2E241C"

    static func hex(for role: WatchFaceColorRole) -> String {
        switch role {
        case .live:
            Self.liveText
        case .flight:
            Self.inFlight
        case .calm:
            Self.calm
        case .alert:
            Self.alert
        }
    }
}
