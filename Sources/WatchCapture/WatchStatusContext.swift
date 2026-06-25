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

    init(
        phase: Phase,
        sessionID: String?,
        startedAt: Date?,
        asOf: Date,
        seq: Int
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.asOf = asOf
        self.seq = seq
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
