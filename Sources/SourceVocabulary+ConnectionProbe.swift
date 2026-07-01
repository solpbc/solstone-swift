// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

extension SourceVocabulary {
    nonisolated static func probeChecked(alive: Bool, milliseconds: Int, relative: String) -> String {
        alive
            ? "checked \(relative) — \(Self.probeReachable) · \(milliseconds) ms"
            : "checked \(relative) — \(Self.probeNotReachable)"
    }

    nonisolated static func probeRelativeLabel(secondsAgo: TimeInterval) -> String {
        if secondsAgo < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(fromTimeInterval: -secondsAgo)
    }
}
