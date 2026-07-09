// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated struct TransferCounters: Codable, Equatable, Sendable {
    var queuedCount: Int
    var attentionCount: Int
    var inFlightCount: Int
    var deliveredCount: Int
    var droppedCount: Int

    static let empty = TransferCounters(
        queuedCount: 0,
        attentionCount: 0,
        inFlightCount: 0,
        deliveredCount: 0,
        droppedCount: 0
    )
}

/// Runtime status for one `sourceKey`. Counters and timestamps are rebuilt in
/// memory and are not persisted as derived state.
nonisolated struct TransferSourceStatusSnapshot: Codable, Equatable, Sendable {
    var queuedCount: Int
    var attentionCount: Int
    var inFlightCount: Int
    var deliveredCount: Int
    var droppedCount: Int
    var lastDeliveredAt: Date?
    var lastErrorDetail: String?
    var recentErrorCount: Int
    var bytesPerSecond: Double
}

/// In-memory status for one queued, attention, or in-flight item. The manifest
/// is the stable item contract; convenience properties forward common fields.
nonisolated struct TransferItemSnapshot: Codable, Equatable, Sendable {
    var manifest: TransferManifest
    var state: TransferRuntimeState
    var attempts: Int

    var itemID: UUID {
        self.manifest.itemID
    }

    var sourceKey: String {
        self.manifest.sourceKey
    }

    var createdAt: Date {
        self.manifest.createdAt
    }

    var nextAttemptAt: Date? {
        self.manifest.nextAttemptAt
    }
}

/// Transfer status is rebuilt from durable queued and attention items plus the
/// current process's in-flight work. Across relaunch, queued and attention
/// items are rebuilt from disk and in-flight starts empty. Runtime-only fields,
/// including lastDeliveredAt, lastErrorDetail, recentErrorCount, throughput,
/// deliveredCount, droppedCount, and attempts, reset on relaunch. A restored
/// item may have a persisted nextAttemptAt while its attempts value is 0.
nonisolated struct TransferStatusSnapshot: Codable, Equatable, Sendable {
    var counters: TransferCounters
    var paused: Bool
    var lastEventSummary: String?
    var lastUpdatedAt: Date
    var sources: [String: TransferSourceStatusSnapshot]
    var aggregateBytesPerSecond: Double
}

@MainActor
@Observable
final class TransferStatusMirror {
    private(set) var queuedCount = 0
    private(set) var attentionCount = 0
    private(set) var inFlightCount = 0
    private(set) var deliveredCount = 0
    private(set) var droppedCount = 0
    private(set) var paused = false
    private(set) var lastEventSummary: String?
    private(set) var lastUpdatedAt: Date?
    private(set) var sources: [String: TransferSourceStatusSnapshot] = [:]
    private(set) var aggregateBytesPerSecond = 0.0
    private(set) var applyCount = 0

    func apply(snapshot: TransferStatusSnapshot) {
        self.queuedCount = snapshot.counters.queuedCount
        self.attentionCount = snapshot.counters.attentionCount
        self.inFlightCount = snapshot.counters.inFlightCount
        self.deliveredCount = snapshot.counters.deliveredCount
        self.droppedCount = snapshot.counters.droppedCount
        self.paused = snapshot.paused
        self.lastEventSummary = snapshot.lastEventSummary
        self.lastUpdatedAt = snapshot.lastUpdatedAt
        self.sources = snapshot.sources
        self.aggregateBytesPerSecond = snapshot.aggregateBytesPerSecond
        self.applyCount += 1
    }
}
