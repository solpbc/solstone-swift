// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OmiHeardRollupLogic {
    static let rowLabel = "heard today"

    static func todayKey(now: Date) -> String {
        ObserverSegmentNaming.dayString(for: now)
    }

    static func durationText(seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "<1m"
        }

        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let totalMinutes = totalSeconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(minutes)m"
        }

        return "\(totalMinutes)m"
    }

    static func heardText(tally: OmiHeardTallyPayload, now: Date) -> String {
        let day = self.todayKey(now: now)
        guard let dayTally = tally[day], dayTally.totalSeconds > 0 else {
            return "nothing yet"
        }

        return self.durationText(seconds: dayTally.totalSeconds)
    }
}
