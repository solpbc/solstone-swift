// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func watchElapsedDisplay(seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 {
        return "\(s)s"
    }
    let totalMinutes = s / 60
    if totalMinutes < 60 {
        return "\(totalMinutes)m"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return "\(hours)h \(minutes)m"
}

nonisolated func watchElapsedSpoken(seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 {
        return s == 1 ? "1 second" : "\(s) seconds"
    }
    let totalMinutes = s / 60
    if totalMinutes < 60 {
        return totalMinutes == 1 ? "1 minute" : "\(totalMinutes) minutes"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    let hourStr = hours == 1 ? "1 hour" : "\(hours) hours"
    if minutes == 0 {
        return hourStr
    }
    let minStr = minutes == 1 ? "1 minute" : "\(minutes) minutes"
    return "\(hourStr), \(minStr)"
}

nonisolated func watchHomeElapsedNextFire(
    sessionStart: Date,
    now: Date,
    sceneActive: Bool,
    luminanceReduced: Bool
) -> Date {
    let elapsed = now.timeIntervalSince(sessionStart)
    if elapsed >= 0 && elapsed < 60 && sceneActive && !luminanceReduced {
        return now.addingTimeInterval(1)
    }
    let nextBoundaryIndex = floor(elapsed / 60.0) + 1.0
    return sessionStart.addingTimeInterval(nextBoundaryIndex * 60.0)
}
