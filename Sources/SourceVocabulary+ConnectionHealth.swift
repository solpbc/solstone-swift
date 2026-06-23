// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

extension SourceVocabulary {
    nonisolated static func standingHealth(
        isConnected: Bool,
        reach: UploadReach
    ) -> (health: ConnectionHealth, syncing: Bool) {
        guard isConnected else {
            return (.unknown, false)
        }

        switch reach {
        case .failing:
            return (.degraded, false)
        case .reaching:
            return (.healthy, true)
        case .idle:
            return (.healthy, false)
        }
    }

    nonisolated static func standingSyncLine(health: ConnectionHealth, syncing: Bool) -> String {
        switch health {
        case .unknown: return Self.standingOffline
        case .degraded: return Self.standingDegraded
        case .healthy: return syncing ? Self.standingSyncing : Self.standingConnected
        }
    }

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
