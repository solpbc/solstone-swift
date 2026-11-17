// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func watchElapsedDisplay(seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 {
        return AppStrings.ios_watchelapsedduration_s("\(s)")
    }
    let totalMinutes = s / 60
    if totalMinutes < 60 {
        return AppStrings.ios_watchelapsedduration_m("\(totalMinutes)")
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return AppStrings.ios_watch_minutes_native("\(hours)", "\(minutes)")
}

nonisolated func watchElapsedSpoken(seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 {
        return AppStrings.ios_plural_watchelapsedduration_n23(s, "\(s)")
    }
    let totalMinutes = s / 60
    if totalMinutes < 60 {
        return AppStrings.ios_plural_watchelapsedduration_n27(totalMinutes, "\(totalMinutes)")
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    let hourStr = AppStrings.ios_plural_watchelapsedduration_n31(hours, "\(hours)")
    if minutes == 0 {
        return hourStr
    }
    let minStr = AppStrings.ios_plural_watchelapsedduration_n35(minutes, "\(minutes)")
    return AppStrings.ios_watch_duration_join(hourStr, minStr)
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
