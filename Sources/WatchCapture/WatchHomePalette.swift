// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchHomePalette {
    static let cream = "#F4EEE4"
    /// Lifted 2026-09-23 for the sun arc's dark row (founder: passing tints, the least-pale of
    /// each hue that clears 4.5:1). The worst background the pattern puts under watch text all
    /// day is `#725B2B`: a 0.20 gold beam over the day halo near the dawn corner, measured with
    /// the real mark every minute of Denver 2026-09-23 over the text area. Before → after:
    /// calm `#B8B8C0` 3.28 → 4.61, live `#F2A457` 3.15 → 4.56, in flight `#F5A842` 3.25 → 4.58,
    /// alert `#FF6B5E` 2.32 → 4.58. Live and in flight are as far apart as the band allows.
    static let calm = "#D9D9E1"
    static let liveText = "#FED0A7"
    static let inFlight = "#FFD19E"
    static let alert = "#FECEC7"
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
