// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchHomePalette {
    static let cream = "#F4EEE4"
    static let calm = "#B8B8C0"
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
