// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ObserverSegmentNaming {
    // Segment formatting remains on ChunkSidecar; this pairs it with the matching day key for writer and spool recovery.
    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func segmentString(for date: Date, durationSeconds: Double) -> String {
        ChunkSidecar.segmentString(for: date, durationSeconds: durationSeconds)
    }
}
