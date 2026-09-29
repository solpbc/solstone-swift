// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct ChunkSidecar: Codable, Equatable, Sendable {
    let segment: String
    let day: String
    let chunkIndex: Int
    let startedAt: Date
    let durationS: TimeInterval
    let sessionID: UUID
    let mode: ObserverMode
    let locationJSONL: Data?

    enum CodingKeys: String, CodingKey {
        case segment
        case day
        case chunkIndex = "chunk_index"
        case startedAt = "started_at"
        case durationS = "duration_s"
        case sessionID = "session_id"
        case mode
        case locationJSONL = "location_jsonl"
    }

    nonisolated static func segmentString(for date: Date, durationSeconds: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        SegmentWireTimeFormatter.configure(formatter)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HHmmss"
        return "\(formatter.string(from: date))_\(max(1, Int(durationSeconds.rounded())))"
    }
}
