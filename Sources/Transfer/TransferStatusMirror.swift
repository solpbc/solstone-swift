// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated struct TransferCounters: Codable, Equatable, Sendable {
    var queuedCount: Int
    var attentionCount: Int
    var inFlightCount: Int
    var deliveredCount: Int

    static let empty = TransferCounters(queuedCount: 0, attentionCount: 0, inFlightCount: 0, deliveredCount: 0)
}

nonisolated struct TransferStatusSnapshot: Codable, Equatable, Sendable {
    var counters: TransferCounters
    var paused: Bool
    var lastEventSummary: String?
    var lastUpdatedAt: Date
}

@MainActor
@Observable
final class TransferStatusMirror {
    private(set) var queuedCount = 0
    private(set) var attentionCount = 0
    private(set) var inFlightCount = 0
    private(set) var deliveredCount = 0
    private(set) var paused = false
    private(set) var lastEventSummary: String?
    private(set) var lastUpdatedAt: Date?
    private(set) var applyCount = 0

    func apply(snapshot: TransferStatusSnapshot) {
        self.queuedCount = snapshot.counters.queuedCount
        self.attentionCount = snapshot.counters.attentionCount
        self.inFlightCount = snapshot.counters.inFlightCount
        self.deliveredCount = snapshot.counters.deliveredCount
        self.paused = snapshot.paused
        self.lastEventSummary = snapshot.lastEventSummary
        self.lastUpdatedAt = snapshot.lastUpdatedAt
        self.applyCount += 1
    }
}
