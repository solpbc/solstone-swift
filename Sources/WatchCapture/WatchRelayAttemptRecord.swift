// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchRelayAttemptTag: Sendable {
    let generation: Int
    let attemptID: UUID
    let attemptStartedAt: Date
}

nonisolated struct WatchRelayAttemptRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let filename = "relay-attempt.json"

    let version: Int
    let segmentID: UUID
    let generation: Int
    let attemptID: UUID
    let attemptStartedAt: Date

    init(
        version: Int = Self.currentVersion,
        segmentID: UUID,
        generation: Int,
        attemptID: UUID,
        attemptStartedAt: Date
    ) {
        self.version = version
        self.segmentID = segmentID
        self.generation = generation
        self.attemptID = attemptID
        self.attemptStartedAt = attemptStartedAt
    }

    var tag: WatchRelayAttemptTag {
        WatchRelayAttemptTag(
            generation: self.generation,
            attemptID: self.attemptID,
            attemptStartedAt: self.attemptStartedAt
        )
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
