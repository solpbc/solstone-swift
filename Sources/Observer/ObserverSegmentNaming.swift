// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ObserverSegmentNaming {
    // Segment formatting remains on ChunkSidecar; this pairs it with the matching day key for writer and spool recovery.
    static func dayString(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        SegmentWireTimeFormatter.configure(formatter)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func segmentString(for date: Date, durationSeconds: Double, timeZone: TimeZone = .current) -> String {
        ChunkSidecar.segmentString(for: date, durationSeconds: durationSeconds, timeZone: timeZone)
    }
}
