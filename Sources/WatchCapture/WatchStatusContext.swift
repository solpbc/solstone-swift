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
    let confirmingCount: Int
    let confirmingHearBackSeconds: Double
    let audioTerminalReason: WatchCaptureTerminalReason?
    let audioTerminalDisposition: WatchCaptureTerminalDisposition?
    let diagnosticsEnvelope: Data?

    enum CodingKeys: String, CodingKey {
        case phase
        case sessionID
        case startedAt
        case asOf
        case seq
        case queuedCount
        case transferringCount
        case confirmingCount
        case confirmingHearBackSeconds
        case audioTerminalReason
        case audioTerminalDisposition
        case diagnosticsEnvelope
    }

    init(
        phase: Phase,
        sessionID: String?,
        startedAt: Date?,
        asOf: Date,
        seq: Int,
        queuedCount: Int,
        transferringCount: Int,
        confirmingCount: Int = 0,
        confirmingHearBackSeconds: Double = 0,
        audioTerminalReason: WatchCaptureTerminalReason? = nil,
        audioTerminalDisposition: WatchCaptureTerminalDisposition? = nil,
        diagnosticsEnvelope: Data? = nil
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.asOf = asOf
        self.seq = seq
        self.queuedCount = queuedCount
        self.transferringCount = transferringCount
        self.confirmingCount = confirmingCount
        self.confirmingHearBackSeconds = confirmingHearBackSeconds
        self.audioTerminalReason = audioTerminalReason
        self.audioTerminalDisposition = audioTerminalDisposition
        self.diagnosticsEnvelope = diagnosticsEnvelope
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
        self.confirmingCount = max(0, try container.decodeIfPresent(Int.self, forKey: .confirmingCount) ?? 0)
        self.confirmingHearBackSeconds = max(0, try container.decodeIfPresent(Double.self, forKey: .confirmingHearBackSeconds) ?? 0)
        self.audioTerminalReason = try container.decodeIfPresent(String.self, forKey: .audioTerminalReason)
            .flatMap { WatchCaptureTerminalReason(rawValue: $0) }
        self.audioTerminalDisposition = try container.decodeIfPresent(String.self, forKey: .audioTerminalDisposition)
            .flatMap { WatchCaptureTerminalDisposition(rawValue: $0) }
        if container.contains(.diagnosticsEnvelope) {
            do {
                self.diagnosticsEnvelope = try container.decodeIfPresent(Data.self, forKey: .diagnosticsEnvelope)
            } catch {
                self.diagnosticsEnvelope = WatchRelayDiagnosticsEnvelope.unavailableData(
                    generatedAt: self.asOf,
                    reason: WatchRelayDiagnosticsEnvelopeReason.unreadable
                )
            }
        } else {
            self.diagnosticsEnvelope = nil
        }
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
        // JSONEncoder does not guarantee object-key order; match sibling Watch encoders.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
