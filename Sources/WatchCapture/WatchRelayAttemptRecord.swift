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

    private enum CodingKeys: String, CodingKey {
        case version
        case segmentID
        case generation
        case attemptID
        case attemptStartedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.segmentID = try container.decode(UUID.self, forKey: .segmentID)
        self.generation = try container.decode(Int.self, forKey: .generation)
        self.attemptID = try container.decode(UUID.self, forKey: .attemptID)
        if let seconds = try? container.decode(Double.self, forKey: .attemptStartedAt),
           seconds.isFinite {
            self.attemptStartedAt = Date(timeIntervalSince1970: seconds)
        } else {
            let string = try container.decode(String.self, forKey: .attemptStartedAt)
            guard let date = ISO8601DateFormatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .attemptStartedAt,
                    in: container,
                    debugDescription: "invalid attempt timestamp"
                )
            }
            self.attemptStartedAt = date
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.segmentID, forKey: .segmentID)
        try container.encode(self.generation, forKey: .generation)
        try container.encode(self.attemptID, forKey: .attemptID)
        try container.encode(self.attemptStartedAt.timeIntervalSince1970, forKey: .attemptStartedAt)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
