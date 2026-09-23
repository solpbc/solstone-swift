// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchHomePalette {
    static let cream = "#F4EEE4"
    /// Lifted 2026-09-23 from `#B8B8C0` for the sun arc's dark row: over the brightest
    /// background the pattern puts under any watch text all day (a 0.20 gold beam over the
    /// halo, `#725B2B`) it measured 3.28:1; `#D9D9E1` measures 4.61:1.
    static let calm = "#D9D9E1"
    static let liveText = "#F2A457"
    static let inFlight = "#F5A842"
    static let alert = "#FF6B5E"
    static let reducedContentOpacity: Double = 0.60

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
