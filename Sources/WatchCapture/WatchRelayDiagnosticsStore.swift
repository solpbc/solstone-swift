// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchRelaySegmentDiagnosticsSidecar: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var segmentID: UUID
    var originalEnqueuedAt: Date?
    var latestEnqueuedAt: Date?
    var attemptCount: Int
    var sourceBytes: Int64?
    var sourcePresent: Bool?
    var lastFacts: WatchRelaySegmentLastFacts

    init(
        version: Int = Self.currentVersion,
        segmentID: UUID,
        originalEnqueuedAt: Date? = nil,
        latestEnqueuedAt: Date? = nil,
        attemptCount: Int = 0,
        sourceBytes: Int64? = nil,
        sourcePresent: Bool? = nil,
        lastFacts: WatchRelaySegmentLastFacts = .empty
    ) {
        self.version = version
        self.segmentID = segmentID
        self.originalEnqueuedAt = originalEnqueuedAt
        self.latestEnqueuedAt = latestEnqueuedAt
        self.attemptCount = attemptCount
        self.sourceBytes = sourceBytes
        self.sourcePresent = sourcePresent
        self.lastFacts = lastFacts
    }
}

nonisolated struct WatchRelayDiagnosticsSummaryFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var lastEnqueue: WatchRelayFactCounter?
    var lastTransferCompletion: WatchRelayTransferCompletionFact?
    var lastStructuredFailure: WatchTransferStructuredFailure?
    var lastDurableACK: WatchRelayFactCounter?
    var lastQueueReconciliationObservation: WatchRelayQueueReconciliationFact?
    var lastBackgroundWakeCompletion: WatchRelayBackgroundWakeFact?
    var lastBackgroundWakeDeadline: WatchRelayBackgroundWakeFact?

    static let empty = WatchRelayDiagnosticsSummaryFile(
        version: Self.currentVersion,
        lastEnqueue: nil,
        lastTransferCompletion: nil,
        lastStructuredFailure: nil,
        lastDurableACK: nil,
        lastQueueReconciliationObservation: nil,
        lastBackgroundWakeCompletion: nil,
        lastBackgroundWakeDeadline: nil
    )

    var lastFactsSummary: WatchRelayLastFactsSummary {
        WatchRelayLastFactsSummary(
            lastEnqueue: self.lastEnqueue,
            lastTransferCompletion: self.lastTransferCompletion,
            lastStructuredFailure: self.lastStructuredFailure,
            lastDurableACK: self.lastDurableACK,
            lastQueueReconciliationObservation: self.lastQueueReconciliationObservation,
            lastBackgroundWakeCompletion: self.lastBackgroundWakeCompletion,
            lastBackgroundWakeDeadline: self.lastBackgroundWakeDeadline
        )
    }
}

nonisolated enum WatchRelayDiagnosticsFiles {
    static let sidecarFilename = "relay-diagnostics.json"
    static let summaryFilename = ".relay-diagnostics-summary.json"

    static func sidecarURL(directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(Self.sidecarFilename, isDirectory: false)
    }

    static func summaryURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(Self.summaryFilename, isDirectory: false)
    }
}

nonisolated enum WatchRelayDiagnosticsStoreError: Error, Equatable, Sendable {
    case unsupportedOrMismatchedSidecar
    case unsupportedSummary
    case invalidNumericInvariant
    case counterOverflow
}
