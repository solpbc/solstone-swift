// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchHomePalette {
    /// The active face's text on brand ink `#1A1A1A`, where the sun arc never draws (founder,
    /// 2026-09-23, the bi-modal watch: "keep the normal colors we have since there's no
    /// contrast issues"). On ink: cream 15.08, calm 8.83, live 8.47, in flight 8.75, alert 6.23.
    static let cream = "#F4EEE4"
    static let calm = "#B8B8C0"
    static let liveText = "#F2A457"
    static let inFlight = "#F5A842"
    static let alert = "#FF6B5E"
    /// Brand ink: the active face's ground.
    static let ground = "#1A1A1A"

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
