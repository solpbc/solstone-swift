// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let watchRelayDiagnosticsLog = Logger(
    subsystem: "app.solstone.swift",
    category: "watch-relay-diagnostics"
)

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

@MainActor
final class WatchRelayDiagnosticsStore {
    static let sidecarFilename = "relay-diagnostics.json"
    static let summaryFilename = ".relay-diagnostics-summary.json"

    private let storage: WatchCaptureStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loggedCorruptURLs: Set<String> = []
    private var historyUnavailableAfterWriteFailure = false

    init(storage: WatchCaptureStorage) {
        self.storage = storage
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func sidecarURL(directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(Self.sidecarFilename, isDirectory: false)
    }

    func summaryURL() -> URL {
        self.storage.rootURL.appendingPathComponent(Self.summaryFilename, isDirectory: false)
    }

    func readSidecar(
        manifest: WatchSegmentManifest,
        directoryURL: URL
    ) -> DiagnosticAvailability<WatchRelaySegmentDiagnosticsSidecar> {
        guard !self.historyUnavailableAfterWriteFailure else {
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        }
        let url = self.sidecarURL(directoryURL: directoryURL)
        guard self.storage.fileWriter.fileExists(at: url) else {
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        }
        do {
            let sidecar = try self.decodeSidecar(from: url, expectedID: manifest.id)
            return .available(sidecar)
        } catch {
            self.resetCorruptDiagnosticFile(at: url, error: error)
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        }
    }

    func readSummary() -> DiagnosticAvailability<WatchRelayLastFactsSummary> {
        guard !self.historyUnavailableAfterWriteFailure else {
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        }
        let url = self.summaryURL()
        guard self.storage.fileWriter.fileExists(at: url) else {
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        }
        do {
            let summary = try self.decodeSummary(from: url)
            return .available(summary.lastFactsSummary)
        } catch {
            self.resetCorruptDiagnosticFile(at: url, error: error)
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        }
    }

    func recordEnqueue(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        bundleURL: URL,
        at date: Date
    ) {
        self.performWrite("enqueue", segmentID: manifest.id) {
            let sourcePresent = self.storage.fileWriter.fileExists(at: bundleURL)
            let sourceBytes = self.sourceByteSize(at: bundleURL, sourcePresent: sourcePresent)
            var sidecar = self.sidecarForUpdate(manifest: manifest, directoryURL: directoryURL)
            if sidecar.originalEnqueuedAt == nil {
                sidecar.originalEnqueuedAt = date
            }
            sidecar.latestEnqueuedAt = date
            sidecar.attemptCount = try Self.incrementCounter(sidecar.attemptCount)
            sidecar.sourceBytes = sourceBytes
            sidecar.sourcePresent = sourcePresent
            let fact = WatchRelayFactCounter(at: date, count: sidecar.attemptCount, segmentID: manifest.id)
            sidecar.lastFacts.lastEnqueue = fact
            try self.writeSidecar(sidecar, directoryURL: directoryURL)

            var summary = self.summaryForUpdate()
            summary.lastEnqueue = fact
            try self.writeSummary(summary)
        }
    }

    func recordTransferCompletion(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        succeeded: Bool,
        failure: WatchConnectivityTransferFailureSnapshot?,
        at date: Date
    ) {
        self.performWrite("transfer completion", segmentID: manifest.id) {
            var summary = self.summaryForUpdate()
            let previousSuccess = summary.lastTransferCompletion?.successCount ?? 0
            let previousFailure = summary.lastTransferCompletion?.failureCount ?? 0
            let completion = WatchRelayTransferCompletionFact(
                at: date,
                segmentID: manifest.id,
                succeeded: succeeded,
                successCount: succeeded ? try Self.incrementCounter(previousSuccess) : previousSuccess,
                failureCount: succeeded ? previousFailure : try Self.incrementCounter(previousFailure)
            )
            var sidecar = self.sidecarForUpdate(manifest: manifest, directoryURL: directoryURL)
            sidecar.lastFacts.lastTransferCompletion = completion
            summary.lastTransferCompletion = completion

            if let failure {
                let structured = WatchTransferStructuredFailure(time: date, snapshot: failure)
                sidecar.lastFacts.lastStructuredFailure = structured
                summary.lastStructuredFailure = structured
            }

            try self.writeSidecar(sidecar, directoryURL: directoryURL)
            try self.writeSummary(summary)
        }
    }

    func recordDurableACK(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        at date: Date
    ) {
        self.performWrite("durable ack", segmentID: manifest.id) {
            var summary = self.summaryForUpdate()
            let count = try Self.incrementCounter(summary.lastDurableACK?.count ?? 0)
            let fact = WatchRelayFactCounter(at: date, count: count, segmentID: manifest.id)

            var sidecar = self.sidecarForUpdate(manifest: manifest, directoryURL: directoryURL)
            sidecar.lastFacts.lastDurableACK = fact
            try self.writeSidecar(sidecar, directoryURL: directoryURL)

            summary.lastDurableACK = fact
            try self.writeSummary(summary)
        }
    }

    func recordQueueReconciliation(
        counts: WatchRelayReconciliationCounts,
        observedFileTransferCount: Int,
        activeManifestCount: Int,
        at date: Date
    ) {
        self.performWrite("queue reconciliation", segmentID: nil) {
            let fact = WatchRelayQueueReconciliationFact(
                at: date,
                counts: counts,
                observedFileTransferCount: observedFileTransferCount,
                activeManifestCount: activeManifestCount
            )

            var summary = self.summaryForUpdate()
            summary.lastQueueReconciliationObservation = fact
            try self.writeSummary(summary)
        }
    }

    func recordBackgroundWake(
        reason: String,
        heldTaskCount: Int,
        completedTaskCount: Int,
        deadlineCount: Int,
        at date: Date
    ) {
        self.performWrite("background wake", segmentID: nil) {
            let fact = WatchRelayBackgroundWakeFact(
                at: date,
                reason: reason,
                heldTaskCount: heldTaskCount,
                completedTaskCount: completedTaskCount,
                deadlineCount: deadlineCount
            )
            var summary = self.summaryForUpdate()
            if reason == "deadline" {
                summary.lastBackgroundWakeDeadline = fact
            } else {
                summary.lastBackgroundWakeCompletion = fact
            }
            try self.writeSummary(summary)
        }
    }
}

private extension WatchRelayDiagnosticsStore {
    func performWrite(_ label: String, segmentID: UUID?, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            self.historyUnavailableAfterWriteFailure = true
            let id = segmentID?.uuidString ?? "none"
            watchRelayDiagnosticsLog.error(
                "watch relay diagnostic \(label, privacy: .public) write failed id=\(id, privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
    }

    func sidecarForUpdate(
        manifest: WatchSegmentManifest,
        directoryURL: URL
    ) -> WatchRelaySegmentDiagnosticsSidecar {
        let url = self.sidecarURL(directoryURL: directoryURL)
        guard self.storage.fileWriter.fileExists(at: url) else {
            return WatchRelaySegmentDiagnosticsSidecar(segmentID: manifest.id)
        }
        do {
            return try self.decodeSidecar(from: url, expectedID: manifest.id)
        } catch {
            self.resetCorruptDiagnosticFile(at: url, error: error)
            return WatchRelaySegmentDiagnosticsSidecar(segmentID: manifest.id)
        }
    }

    func summaryForUpdate() -> WatchRelayDiagnosticsSummaryFile {
        let url = self.summaryURL()
        guard self.storage.fileWriter.fileExists(at: url) else {
            return .empty
        }
        do {
            return try self.decodeSummary(from: url)
        } catch {
            self.resetCorruptDiagnosticFile(at: url, error: error)
            return .empty
        }
    }

    func sourceByteSize(at url: URL, sourcePresent: Bool) -> Int64? {
        guard sourcePresent else { return nil }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            return Int64(fileSize)
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return nil
    }

    func decodeSidecar(
        from url: URL,
        expectedID: UUID
    ) throws -> WatchRelaySegmentDiagnosticsSidecar {
        let sidecar = try self.decoder.decode(
            WatchRelaySegmentDiagnosticsSidecar.self,
            from: self.storage.fileWriter.readData(from: url)
        )
        guard sidecar.version <= WatchRelaySegmentDiagnosticsSidecar.currentVersion,
              sidecar.segmentID == expectedID
        else {
            throw WatchRelayDiagnosticsStoreError.unsupportedOrMismatchedSidecar
        }
        try Self.validateSidecarInvariants(sidecar)
        return sidecar
    }

    func decodeSummary(from url: URL) throws -> WatchRelayDiagnosticsSummaryFile {
        let summary = try self.decoder.decode(
            WatchRelayDiagnosticsSummaryFile.self,
            from: self.storage.fileWriter.readData(from: url)
        )
        guard summary.version <= WatchRelayDiagnosticsSummaryFile.currentVersion else {
            throw WatchRelayDiagnosticsStoreError.unsupportedSummary
        }
        try Self.validateSummaryInvariants(summary)
        return summary
    }

    func writeSidecar(_ sidecar: WatchRelaySegmentDiagnosticsSidecar, directoryURL: URL) throws {
        let data = try self.encoder.encode(sidecar)
        try self.storage.fileWriter.writeData(
            data,
            to: self.sidecarURL(directoryURL: directoryURL),
            options: .atomic
        )
    }

    func writeSummary(_ summary: WatchRelayDiagnosticsSummaryFile) throws {
        let data = try self.encoder.encode(summary)
        try self.storage.fileWriter.writeData(data, to: self.summaryURL(), options: .atomic)
    }

    func resetCorruptDiagnosticFile(at url: URL, error: any Error) {
        let key = url.standardizedFileURL.path
        if self.loggedCorruptURLs.insert(key).inserted {
            watchRelayDiagnosticsLog.error(
                "watch relay diagnostic file reset path=\(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
        try? self.storage.fileWriter.removeItem(at: url)
    }

    nonisolated static func incrementCounter(_ current: Int) throws -> Int {
        let (next, overflow) = max(0, current).addingReportingOverflow(1)
        guard !overflow, next < Int.max else {
            throw WatchRelayDiagnosticsStoreError.counterOverflow
        }
        return next
    }

    nonisolated static func validateSidecarInvariants(_ sidecar: WatchRelaySegmentDiagnosticsSidecar) throws {
        try self.validateCounter(sidecar.attemptCount)
        if let sourceBytes = sidecar.sourceBytes {
            try self.validateNonNegative(sourceBytes)
        }
        try self.validateSegmentLastFacts(sidecar.lastFacts)
    }

    nonisolated static func validateSummaryInvariants(_ summary: WatchRelayDiagnosticsSummaryFile) throws {
        try self.validateFactCounter(summary.lastEnqueue)
        try self.validateTransferCompletion(summary.lastTransferCompletion)
        try self.validateFactCounter(summary.lastDurableACK)
        try self.validateQueueReconciliation(summary.lastQueueReconciliationObservation)
        try self.validateBackgroundWake(summary.lastBackgroundWakeCompletion)
        try self.validateBackgroundWake(summary.lastBackgroundWakeDeadline)
    }

    nonisolated static func validateSegmentLastFacts(_ facts: WatchRelaySegmentLastFacts) throws {
        try self.validateFactCounter(facts.lastEnqueue)
        try self.validateTransferCompletion(facts.lastTransferCompletion)
        try self.validateFactCounter(facts.lastDurableACK)
        try self.validateQueueReconciliation(facts.lastQueueReconciliationObservation)
    }

    nonisolated static func validateFactCounter(_ fact: WatchRelayFactCounter?) throws {
        guard let fact else { return }
        try self.validateCounter(fact.count)
    }

    nonisolated static func validateTransferCompletion(_ fact: WatchRelayTransferCompletionFact?) throws {
        guard let fact else { return }
        try self.validateCounter(fact.successCount)
        try self.validateCounter(fact.failureCount)
    }

    nonisolated static func validateQueueReconciliation(_ fact: WatchRelayQueueReconciliationFact?) throws {
        guard let fact else { return }
        try self.validateReconciliationCounts(fact.counts)
        try self.validateCounter(fact.observedFileTransferCount)
        try self.validateCounter(fact.activeManifestCount)
    }

    nonisolated static func validateReconciliationCounts(_ counts: WatchRelayReconciliationCounts) throws {
        try self.validateCounter(counts.matched)
        try self.validateCounter(counts.appActiveNotObserved)
        try self.validateCounter(counts.duplicate)
        try self.validateCounter(counts.orphaned)
        try self.validateCounter(counts.unparseable)
    }

    nonisolated static func validateBackgroundWake(_ fact: WatchRelayBackgroundWakeFact?) throws {
        guard let fact else { return }
        try self.validateCounter(fact.heldTaskCount)
        try self.validateCounter(fact.completedTaskCount)
        try self.validateCounter(fact.deadlineCount)
    }

    nonisolated static func validateCounter(_ value: Int) throws {
        guard value >= 0, value < Int.max else {
            throw WatchRelayDiagnosticsStoreError.invalidNumericInvariant
        }
    }

    nonisolated static func validateNonNegative(_ value: Int64) throws {
        guard value >= 0 else {
            throw WatchRelayDiagnosticsStoreError.invalidNumericInvariant
        }
    }
}

nonisolated enum WatchRelayDiagnosticsStoreError: Error, Equatable, Sendable {
    case unsupportedOrMismatchedSidecar
    case unsupportedSummary
    case invalidNumericInvariant
    case counterOverflow
}
