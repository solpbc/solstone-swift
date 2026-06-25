// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

nonisolated enum WatchComplicationPalette {
    static func color(for role: WatchFaceColorRole) -> Color {
        switch role {
        case .live:
            Color(red: 0.910, green: 0.573, blue: 0.227)
        case .flight:
            Color(red: 0.961, green: 0.659, blue: 0.259)
        case .calm:
            Color(red: 0.604, green: 0.604, blue: 0.627)
        case .alert:
            Color(red: 1.000, green: 0.271, blue: 0.227)
        }
    }
}
