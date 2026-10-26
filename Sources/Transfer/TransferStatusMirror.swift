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
    /// Of `attentionCount`, the refusals the engine is pacing: nothing sends them until a new
    /// connection's round offers them again, so a drain has nothing to wait for on their account.
    /// They stay in `attentionCount`, which is what the owner sees as held.
    var refusalPacedCount = 0
    /// When `lastErrorDetail` happened, and the times of the errors since the source's last delivery.
    var lastErrorAt: Date?
    var errorTimesSinceDelivery: [Date]?
}

/// In-memory status for one queued, attention, or in-flight item. The manifest
/// is the stable item contract; convenience properties forward common fields.
nonisolated struct TransferItemSnapshot: Codable, Equatable, Sendable {
    var manifest: TransferManifest
    var state: TransferRuntimeState
    var attempts: Int
    /// The journal turned this item away for its own envelope and nothing it was refused under
    /// has changed: the round on a new connection skips it until a day has passed, the app or
    /// journal is updated, or the owner retries it. Decided by the engine; screens read it and
    /// never work it out themselves.
    var refusalPaced: Bool

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
    var policyPaused: Bool
    var backoffPendingCount: Int
    var soonestNextAttemptAt: Date?
    var endpointHeld: Bool
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
    private(set) var policyPaused = false
    private(set) var backoffPendingCount = 0
    private(set) var soonestNextAttemptAt: Date?
    private(set) var endpointHeld = false
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
        self.policyPaused = snapshot.policyPaused
        self.backoffPendingCount = snapshot.backoffPendingCount
        self.soonestNextAttemptAt = snapshot.soonestNextAttemptAt
        self.endpointHeld = snapshot.endpointHeld
        self.lastEventSummary = snapshot.lastEventSummary
        self.lastUpdatedAt = snapshot.lastUpdatedAt
        self.sources = snapshot.sources
        self.aggregateBytesPerSecond = snapshot.aggregateBytesPerSecond
        self.applyCount += 1
    }
}

/// A transfer error that is still news: it happened in the last 15 minutes and no delivery on its
/// source succeeded at or after it. Decided when it is shown, never when the engine last updated,
/// so an old error ages out even when nothing else happens.
nonisolated struct TransferRecentError: Equatable, Sendable {
    static let window: TimeInterval = 15 * 60

    let detail: String
    let at: Date
    /// Errors in the window after the source's last delivery, this one included.
    let count: Int

    static func evaluate(_ status: TransferSourceStatusSnapshot, now: Date) -> TransferRecentError? {
        guard let detail = status.lastErrorDetail, let at = status.lastErrorAt else { return nil }
        let floor = now.addingTimeInterval(-Self.window)
        func isRecent(_ time: Date) -> Bool {
            guard time >= floor, time <= now else { return false }
            guard let delivered = status.lastDeliveredAt else { return true }
            return time > delivered
        }
        guard isRecent(at) else { return nil }
        let count = (status.errorTimesSinceDelivery ?? [at]).filter(isRecent).count
        return TransferRecentError(detail: detail, at: at, count: max(1, count))
    }
}
