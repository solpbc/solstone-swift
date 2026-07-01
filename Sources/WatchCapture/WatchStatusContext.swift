// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchStatusContext: Codable, Equatable, Sendable {
    nonisolated enum Phase: String, Codable, Equatable, Sendable {
        case idle
        case observing
        case stopping
    }

    static let applicationContextKey = "watchStatus"

    let phase: Phase
    let sessionID: String?
    let startedAt: Date?
    let asOf: Date
    let seq: Int
    let queuedCount: Int
    let transferringCount: Int

    enum CodingKeys: String, CodingKey {
        case phase
        case sessionID
        case startedAt
        case asOf
        case seq
        case queuedCount
        case transferringCount
    }

    init(
        phase: Phase,
        sessionID: String?,
        startedAt: Date?,
        asOf: Date,
        seq: Int,
        queuedCount: Int,
        transferringCount: Int
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.asOf = asOf
        self.seq = seq
        self.queuedCount = queuedCount
        self.transferringCount = transferringCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.phase = try container.decode(Phase.self, forKey: .phase)
        self.sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.asOf = try container.decode(Date.self, forKey: .asOf)
        self.seq = try container.decode(Int.self, forKey: .seq)
        self.queuedCount = max(0, try container.decodeIfPresent(Int.self, forKey: .queuedCount) ?? 0)
        self.transferringCount = max(0, try container.decodeIfPresent(Int.self, forKey: .transferringCount) ?? 0)
    }

    func applicationContext() -> [String: Any] {
        guard let data = try? Self.makeEncoder().encode(self) else {
            return [:]
        }
        return [Self.applicationContextKey: data]
    }

    init?(applicationContext: [String: Any]) {
        guard let data = applicationContext[Self.applicationContextKey] as? Data,
              let decoded = try? Self.makeDecoder().decode(Self.self, from: data)
        else {
            return nil
        }
        self = decoded
    }
}

private extension WatchStatusContext {
    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
