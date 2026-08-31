// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let watchRelayDiagnosticsLog = Logger(
    subsystem: "app.solstone.swift",
    category: "watch-relay-diagnostics"
)

nonisolated struct WatchCaptureStoragePaths: Sendable {
    static let rootDirectoryName = "WatchCapture"
    static let sessionRecordFileName = "watch-capture-session.json"

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    init(fileManager: FileManager = .default) throws {
        self.init(rootURL: try AppGroupContainer.rootURL(fileManager: fileManager)
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true))
    }

    func segmentDirectoryURL(day: String, segment: String) -> URL {
        self.rootURL.appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(segment, isDirectory: true)
    }

    func dayString(for date: Date) -> String {
        Self.dayString(for: date)
    }

    func segmentString(for date: Date, durationSeconds: Double) -> String {
        Self.segmentString(for: date, durationSeconds: durationSeconds)
    }

    func provisionalSegmentString(for date: Date) -> String {
        Self.segmentString(for: date, durationSeconds: 1)
    }

    func manifestURL(directory: URL) -> URL { directory.appendingPathComponent("manifest.json") }
    func audioURL(directory: URL) -> URL { directory.appendingPathComponent("audio.m4a") }
    func locationURL(directory: URL) -> URL { directory.appendingPathComponent("location.jsonl") }
    func sessionRecordURL() -> URL { self.rootURL.appendingPathComponent(Self.sessionRecordFileName) }
    func sessionHistoryURL() -> URL { self.rootURL.appendingPathComponent(WatchCaptureStorageActor.historyFileName) }
    func sessionHistoryCounterURL() -> URL { self.rootURL.appendingPathComponent(WatchCaptureStorageActor.counterFileName) }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func segmentString(for date: Date, durationSeconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "HHmmss"
        return "\(formatter.string(from: date))_\(max(1, Int(durationSeconds.rounded())))"
    }
}

nonisolated enum WatchCaptureCatalogRootIssue: String, Codable, Equatable, Sendable {
    case missing
    case notDirectory
    case unreadable
    case notEnumerable
}

nonisolated enum WatchCaptureCatalogRootState: Codable, Equatable, Sendable {
    case unavailable(WatchCaptureCatalogRootIssue)
    case emptyComplete
    case complete
    case partial

    var canInferUUIDAbsence: Bool {
        switch self {
        case .emptyComplete, .complete: true
        case .unavailable, .partial: false
        }
    }
}

nonisolated struct WatchCaptureCatalogEntryID: Codable, Hashable, Sendable {
    let day: String
    let segment: String
}

nonisolated struct WatchCaptureContentWitness: Equatable, Sendable {
    let manifestData: Data
    let audioBytes: Int64?
    let locationBytes: Int64?
    let audioFingerprint: WatchCaptureStorageFileFingerprint?
    let locationFingerprint: WatchCaptureStorageFileFingerprint?

    init(
        manifestData: Data,
        audioBytes: Int64?,
        locationBytes: Int64?,
        audioFingerprint: WatchCaptureStorageFileFingerprint? = nil,
        locationFingerprint: WatchCaptureStorageFileFingerprint? = nil
    ) {
        self.manifestData = manifestData
        self.audioBytes = audioBytes
        self.locationBytes = locationBytes
        self.audioFingerprint = audioFingerprint
        self.locationFingerprint = locationFingerprint
    }
}

nonisolated struct WatchCaptureCatalogEntry: Sendable {
    let id: WatchCaptureCatalogEntryID
    let directoryURL: URL
    let manifestURL: URL
    let manifest: WatchSegmentManifest
    let witness: WatchCaptureContentWitness
}

nonisolated enum WatchCaptureCatalogIssueKind: String, Codable, Equatable, Sendable {
    case manifestDecodeFailure
    case fileTypeLookupFailure
    case unexpectedShape
    case missingManifest
    case pathMismatch
    case duplicateManifestUUID
    case incompleteSubtree
}

nonisolated struct WatchCaptureCatalogIssue: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: WatchCaptureCatalogIssueKind
    let namespace: String
}

nonisolated struct WatchCaptureCatalog: Sendable {
    let rootState: WatchCaptureCatalogRootState
    let entries: [WatchCaptureCatalogEntry]
    let issues: [WatchCaptureCatalogIssue]

    var canInferUUIDAbsence: Bool { self.rootState.canInferUUIDAbsence }
}

nonisolated enum WatchCaptureStorageConflict: Error, Equatable, Sendable {
    case staleQueuedSnapshot(id: UUID, expected: WatchSegmentState, actual: WatchSegmentState)
    case contentWitnessChanged(id: WatchCaptureCatalogEntryID)
    case staleAcknowledgementReplacement(id: UUID, expected: WatchCaptureCatalogEntryID, found: WatchCaptureCatalogEntryID?)
}

nonisolated struct WatchCaptureLocationLogFinalizedStats: Equatable, Sendable {
    let fixCount: Int
    let gap: Bool
}

nonisolated struct WatchRelayStorageTransition: Sendable {
    let entry: WatchCaptureCatalogEntry
    let didChange: Bool
}

nonisolated struct WatchRelayTransferPreparation: Sendable {
    let bundleURL: URL
    let manifest: WatchSegmentManifest
    let attempt: WatchRelayAttemptRecord?
    let bundleCleanupFailed: Bool
    let attemptCleanupFailed: Bool
    let attemptFailure: WatchConnectivityTransferFailureSnapshot?
}

/// The Watch app's single owner for durable capture files and catalog reads.
/// Its initializer intentionally only receives paths; root creation is delayed until a mutation.
actor WatchCaptureStorageActor {
    static let historyFileName = ".watch-capture-session-history.jsonl"
    static let counterFileName = ".watch-capture-session-counter.json"
    private static let maximumSessionHistoryEntryCount = 40
    private static let sessionHistoryRetention: TimeInterval = 7 * 24 * 60 * 60

    private let paths: WatchCaptureStoragePaths
    private let fileWriter: any WatchFileWriting
    private let audioProbe: any WatchAudioProbing
    private let manifestEncoder: JSONEncoder
    private let manifestDecoder: JSONDecoder
    private let sessionEncoder: JSONEncoder
    private let sessionDecoder: JSONDecoder
    private let locationEncoder: JSONEncoder
    private let diagnosticsEncoder: JSONEncoder
    private let diagnosticsDecoder: JSONDecoder
    private let storageSignposter: WatchStorageSignposter
    private var transactionIsActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
    private var loggedCorruptDiagnosticURLs: Set<String> = []
    private var diagnosticsUnavailableAfterWriteFailure = false

    init(
        paths: WatchCaptureStoragePaths,
        fileWriter: any WatchFileWriting,
        audioProbe: any WatchAudioProbing = LiveWatchAudioProbe(),
        storageSignposter: WatchStorageSignposter = WatchStorageSignposter()
    ) {
        self.paths = paths
        self.fileWriter = fileWriter
        self.audioProbe = audioProbe
        self.storageSignposter = storageSignposter
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.manifestEncoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.manifestDecoder = decoder
        self.sessionEncoder = WatchRelayDiagnosticsEnvelope.makeEncoder()
        self.sessionDecoder = WatchRelayDiagnosticsEnvelope.makeDecoder()
        let locationEncoder = JSONEncoder()
        locationEncoder.dateEncodingStrategy = .iso8601
        locationEncoder.outputFormatting = [.sortedKeys]
        self.locationEncoder = locationEncoder
        let diagnosticsEncoder = JSONEncoder()
        diagnosticsEncoder.dateEncodingStrategy = .iso8601
        diagnosticsEncoder.outputFormatting = [.sortedKeys]
        self.diagnosticsEncoder = diagnosticsEncoder
        let diagnosticsDecoder = JSONDecoder()
        diagnosticsDecoder.dateDecodingStrategy = .iso8601
        self.diagnosticsDecoder = diagnosticsDecoder
    }

    func prepareRoot() async throws {
        try await self.withTransaction(.capturePreparation) {
            try await self.fileWriter.createDirectory(at: self.paths.rootURL)
        }
    }

    func prepareSegmentDirectory(day: String, segment: String) async throws -> URL {
        try await self.withTransaction(.capturePreparation) {
            let directory = self.paths.segmentDirectoryURL(day: day, segment: segment)
            if await self.fileWriter.fileExists(at: directory) {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteFileExistsError,
                    userInfo: [NSFilePathErrorKey: directory.path]
                )
            }
            try await self.fileWriter.createDirectory(at: directory)
            return directory
        }
    }

    func moveSegmentDirectoryIfNeeded(
        currentURL: URL,
        day: String,
        currentSegment: String,
        finalSegment: String
    ) async throws -> URL {
        try await self.withTransaction(.captureFinalization) {
            guard currentSegment != finalSegment else { return currentURL }
            let finalURL = self.paths.segmentDirectoryURL(day: day, segment: finalSegment)
            try await self.fileWriter.moveItem(at: currentURL, to: finalURL)
            return finalURL
        }
    }

    func fileExists(at url: URL) async -> Bool {
        await self.withTransaction {
            await self.fileWriter.fileExists(at: url)
        }
    }

    func fileSize(at url: URL) async throws -> Int64 {
        try await self.withTransaction {
            try await self.fileWriter.fileSize(at: url)
        }
    }

    func removeItem(at url: URL) async throws {
        try await self.withTransaction {
            try await self.fileWriter.removeItem(at: url)
        }
    }

    func writeComplicationSnapshot(_ data: Data, to url: URL) async throws {
        try await self.withTransaction(.complicationSnapshot) {
            try await self.fileWriter.writeData(data, to: url, options: .atomic)
        }
    }

    func removeSegmentDirectoryIfMediaIsProvablyEmpty(at directory: URL) async -> Bool {
        await self.withTransaction(.captureFinalization) {
            let mediaURLs = [
                self.paths.audioURL(directory: directory),
                self.paths.locationURL(directory: directory),
            ]
            for url in mediaURLs {
                do {
                    guard try await self.fileWriter.fileSize(at: url) == 0 else { return false }
                } catch {
                    return false
                }
            }
            do {
                try await self.fileWriter.removeItem(at: directory)
                return true
            } catch {
                return false
            }
        }
    }

    func probeAudio(at url: URL) async -> WatchAudioProbeResult {
        await self.withTransaction(.captureFinalization) {
            do {
                _ = try await self.fileWriter.readData(from: url)
            } catch {
                return .ioUnknown
            }
            return await self.audioProbe.probe(at: url)
        }
    }

    func scanCatalog() async -> WatchCaptureCatalog {
        await self.withTransaction(.manifestScan) {
            await self.scanCatalogInner()
        }
    }

    func writeManifest(
        _ manifest: WatchSegmentManifest,
        entry: WatchCaptureCatalogEntry? = nil,
        ensuringDirectory: Bool = true
    ) async throws {
        try await self.withTransaction(.storageActorManifestWrite) {
            let directory = entry?.directoryURL ?? self.paths.segmentDirectoryURL(day: manifest.day, segment: manifest.segment)
            if let entry {
                let current = try await self.fileWriter.readData(from: entry.manifestURL)
                guard current == entry.witness.manifestData else { throw WatchCaptureStorageConflict.contentWitnessChanged(id: entry.id) }
            } else if ensuringDirectory {
                try await self.prepareRootInner()
                try await self.fileWriter.createDirectory(at: directory)
            }
            try await self.fileWriter.writeData(
                try self.manifestEncoder.encode(manifest),
                to: self.paths.manifestURL(directory: directory),
                options: .atomic
            )
        }
    }

    func promoteQueuedForRelay(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(.relaySegmentTransition) {
            let current = try await self.currentRelayEntry(entry)
            guard current.manifest.state == .queued else {
                throw self.staleState(entry, expected: .queued, actual: current.manifest.state)
            }
            try self.verifyRelayWitness(current, against: entry)
            var manifest = current.manifest
            manifest.state = .transferring
            return WatchRelayStorageTransition(
                entry: try await self.writeRelayManifest(manifest, replacing: current),
                didChange: true
            )
        }
    }

    func adoptQueuedForRelay(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(.relaySegmentTransition) {
            let current = try await self.currentRelayEntry(entry)
            switch current.manifest.state {
            case .queued:
                try self.verifyRelayWitness(current, against: entry)
                var manifest = current.manifest
                manifest.state = .transferring
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current),
                    didChange: true
                )
            case .transferring:
                try self.verifyRelayWitness(current, against: entry)
                return WatchRelayStorageTransition(entry: current, didChange: false)
            default:
                throw self.staleState(entry, expected: .queued, actual: current.manifest.state)
            }
        }
    }

    func requeueFailedRelayTransfer(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(.relaySegmentTransition) {
            let current = try await self.currentRelayEntry(entry)
            switch current.manifest.state {
            case .transferring:
                try self.verifyRelayWitness(current, against: entry)
                var manifest = current.manifest
                manifest.state = .queued
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current),
                    didChange: true
                )
            case .queued:
                try self.verifyRelayWitness(current, against: entry)
                return WatchRelayStorageTransition(entry: current, didChange: false)
            default:
                throw self.staleState(entry, expected: .transferring, actual: current.manifest.state)
            }
        }
    }

    func markRelayTransferDelivered(
        _ entry: WatchCaptureCatalogEntry,
        at deliveredAt: Date
    ) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(.relaySegmentTransition) {
            let current = try await self.currentRelayEntry(entry)
            switch current.manifest.state {
            case .transferring, .queued:
                try self.verifyRelayWitness(current, against: entry)
                var manifest = current.manifest
                manifest.state = .delivered
                manifest.deliveredAt = deliveredAt
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current),
                    didChange: true
                )
            case .delivered:
                try self.verifyRelayWitness(current, against: entry)
                return WatchRelayStorageTransition(entry: current, didChange: false)
            default:
                throw self.staleState(entry, expected: entry.manifest.state, actual: current.manifest.state)
            }
        }
    }

    func acknowledgeRelaySegment(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(.relaySegmentTransition) {
            let current = try await self.verifiedRelayEntry(entry)
            switch current.manifest.state {
            case .acked, .safeToDelete:
                return WatchRelayStorageTransition(entry: current, didChange: false)
            default:
                var manifest = current.manifest
                manifest.state = .acked
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current),
                    didChange: true
                )
            }
        }
    }

    func markRelaySegmentSafeToDelete(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(.relaySegmentTransition) {
            let current = try await self.currentRelayEntry(entry)
            switch current.manifest.state {
            case .acked:
                try self.verifyRelayWitness(current, against: entry)
                var manifest = current.manifest
                manifest.state = .safeToDelete
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current),
                    didChange: true
                )
            case .safeToDelete:
                try self.verifyRelayWitness(current, against: entry)
                return WatchRelayStorageTransition(entry: current, didChange: false)
            default:
                throw self.staleState(entry, expected: .acked, actual: current.manifest.state)
            }
        }
    }

    func deleteAcknowledgedRelaySegment(
        _ entry: WatchCaptureCatalogEntry,
        bundleURL: URL
    ) async throws {
        try await self.withTransaction(.relayCleanupScan) {
            let current = try await self.verifiedRelayDeletionEntry(entry)
            guard current.manifest.state == .safeToDelete else {
                throw self.staleState(entry, expected: .safeToDelete, actual: current.manifest.state)
            }
            try await self.fileWriter.removeItem(at: current.directoryURL)
            try? await self.fileWriter.removeItem(at: bundleURL)
        }
    }

    func refreshRelayDeliveredDeadline(
        _ entry: WatchCaptureCatalogEntry,
        at now: Date,
        deadline: TimeInterval
    ) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(.relaySegmentTransition) {
            let current = try await self.currentRelayEntry(entry)
            guard current.manifest.state == .delivered else {
                throw self.staleState(entry, expected: .delivered, actual: current.manifest.state)
            }
            try self.verifyRelayWitness(current, against: entry)
            var manifest = current.manifest
            guard let deliveredAt = manifest.deliveredAt else {
                manifest.deliveredAt = now
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current),
                    didChange: true
                )
            }
            guard now.timeIntervalSince(deliveredAt) >= deadline else {
                return WatchRelayStorageTransition(entry: current, didChange: false)
            }
            manifest.state = .queued
            manifest.deliveredAt = nil
            return WatchRelayStorageTransition(
                entry: try await self.writeRelayManifest(manifest, replacing: current),
                didChange: true
            )
        }
    }

    func prepareRelayTransfer(
        _ entry: WatchCaptureCatalogEntry,
        bundleURL: URL,
        attempt: WatchRelayAttemptRecord
    ) async throws -> WatchRelayTransferPreparation {
        try await self.withTransaction(.relayBundleWrite) {
            let current = try await self.currentRelayEntry(entry)
            guard current.manifest.state == .transferring else {
                throw self.staleState(entry, expected: .transferring, actual: current.manifest.state)
            }
            try self.verifyRelayWitness(current, against: entry)

            var bundleCleanupFailed = false
            do {
                try await self.fileWriter.removeItem(at: bundleURL)
            } catch {
                bundleCleanupFailed = true
            }
            let bundleData = try await self.relayBundleData(for: current)
            try await self.fileWriter.writeData(bundleData, to: bundleURL, options: .atomic)

            let attemptURL = current.directoryURL
                .appendingPathComponent(WatchRelayAttemptRecord.filename, isDirectory: false)
            do {
                try await self.fileWriter.writeData(
                    try WatchRelayAttemptRecord.makeEncoder().encode(attempt),
                    to: attemptURL,
                    options: .atomic
                )
                return WatchRelayTransferPreparation(
                    bundleURL: bundleURL,
                    manifest: current.manifest,
                    attempt: attempt,
                    bundleCleanupFailed: bundleCleanupFailed,
                    attemptCleanupFailed: false,
                    attemptFailure: nil
                )
            } catch {
                let failure = WatchConnectivityTransferFailureSnapshot(error: error)
                var attemptCleanupFailed = false
                do {
                    try await self.fileWriter.removeItem(at: attemptURL)
                } catch {
                    attemptCleanupFailed = true
                }
                return WatchRelayTransferPreparation(
                    bundleURL: bundleURL,
                    manifest: current.manifest,
                    attempt: nil,
                    bundleCleanupFailed: bundleCleanupFailed,
                    attemptCleanupFailed: attemptCleanupFailed,
                    attemptFailure: failure
                )
            }
        }
    }

    func readDiagnosticsSidecar(
        manifest: WatchSegmentManifest,
        directoryURL: URL
    ) async -> DiagnosticAvailability<WatchRelaySegmentDiagnosticsSidecar> {
        await self.withTransaction(.diagnosticsHistorySummaryRead) {
            guard !self.diagnosticsUnavailableAfterWriteFailure else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            let url = WatchRelayDiagnosticsFiles.sidecarURL(directoryURL: directoryURL)
            guard await self.fileWriter.fileExists(at: url) else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            do {
                return .available(try await self.decodeDiagnosticsSidecar(from: url, expectedID: manifest.id))
            } catch {
                await self.resetCorruptDiagnosticFile(at: url, error: error)
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
        }
    }

    func readDiagnosticsSummary() async -> DiagnosticAvailability<WatchRelayLastFactsSummary> {
        await self.withTransaction(.diagnosticsHistorySummaryRead) {
            guard !self.diagnosticsUnavailableAfterWriteFailure else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            let url = WatchRelayDiagnosticsFiles.summaryURL(rootURL: self.paths.rootURL)
            guard await self.fileWriter.fileExists(at: url) else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            do {
                return .available(try await self.decodeDiagnosticsSummary(from: url).lastFactsSummary)
            } catch {
                await self.resetCorruptDiagnosticFile(at: url, error: error)
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
        }
    }

    func recordRelayEnqueue(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        bundleURL: URL,
        at date: Date
    ) async -> Bool {
        await self.withTransaction(.relayDiagnosticsPersistence) {
            await self.performDiagnosticsWrite("enqueue", segmentID: manifest.id) {
                let sourcePresent = await self.fileWriter.fileExists(at: bundleURL)
                let sourceBytes = await self.diagnosticsSourceByteSize(at: bundleURL, sourcePresent: sourcePresent)
                var sidecar = await self.diagnosticsSidecarForUpdate(manifest: manifest, directoryURL: directoryURL)
                if sidecar.originalEnqueuedAt == nil {
                    sidecar.originalEnqueuedAt = date
                }
                sidecar.latestEnqueuedAt = date
                sidecar.attemptCount = try Self.incrementDiagnosticsCounter(sidecar.attemptCount)
                sidecar.sourceBytes = sourceBytes
                sidecar.sourcePresent = sourcePresent
                let fact = WatchRelayFactCounter(at: date, count: sidecar.attemptCount, segmentID: manifest.id)
                sidecar.lastFacts.lastEnqueue = fact
                try await self.writeDiagnosticsSidecar(sidecar, directoryURL: directoryURL)

                var summary = await self.diagnosticsSummaryForUpdate()
                summary.lastEnqueue = fact
                try await self.writeDiagnosticsSummary(summary)
            }
        }
    }

    func recordRelayTransferCompletion(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        succeeded: Bool,
        failure: WatchConnectivityTransferFailureSnapshot?,
        at date: Date
    ) async {
        _ = await self.withTransaction(.relayDiagnosticsPersistence) {
            await self.performDiagnosticsWrite("transfer completion", segmentID: manifest.id) {
                var summary = await self.diagnosticsSummaryForUpdate()
                let previousSuccess = summary.lastTransferCompletion?.successCount ?? 0
                let previousFailure = summary.lastTransferCompletion?.failureCount ?? 0
                let completion = WatchRelayTransferCompletionFact(
                    at: date,
                    segmentID: manifest.id,
                    succeeded: succeeded,
                    successCount: succeeded ? try Self.incrementDiagnosticsCounter(previousSuccess) : previousSuccess,
                    failureCount: succeeded ? previousFailure : try Self.incrementDiagnosticsCounter(previousFailure)
                )
                var sidecar = await self.diagnosticsSidecarForUpdate(manifest: manifest, directoryURL: directoryURL)
                sidecar.lastFacts.lastTransferCompletion = completion
                summary.lastTransferCompletion = completion
                if let failure {
                    let structured = WatchTransferStructuredFailure(time: date, snapshot: failure)
                    sidecar.lastFacts.lastStructuredFailure = structured
                    summary.lastStructuredFailure = structured
                }
                try await self.writeDiagnosticsSidecar(sidecar, directoryURL: directoryURL)
                try await self.writeDiagnosticsSummary(summary)
            }
        }
    }

    func recordRelayDurableACK(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        at date: Date
    ) async {
        _ = await self.withTransaction(.relayDiagnosticsPersistence) {
            await self.performDiagnosticsWrite("durable ack", segmentID: manifest.id) {
                var summary = await self.diagnosticsSummaryForUpdate()
                let count = try Self.incrementDiagnosticsCounter(summary.lastDurableACK?.count ?? 0)
                let fact = WatchRelayFactCounter(at: date, count: count, segmentID: manifest.id)
                var sidecar = await self.diagnosticsSidecarForUpdate(manifest: manifest, directoryURL: directoryURL)
                sidecar.lastFacts.lastDurableACK = fact
                try await self.writeDiagnosticsSidecar(sidecar, directoryURL: directoryURL)
                summary.lastDurableACK = fact
                try await self.writeDiagnosticsSummary(summary)
            }
        }
    }

    func recordRelayQueueReconciliation(
        counts: WatchRelayReconciliationCounts,
        observedFileTransferCount: Int,
        activeManifestCount: Int,
        at date: Date
    ) async -> Bool {
        await self.withTransaction(.relayDiagnosticsPersistence) {
            await self.performDiagnosticsWrite("queue reconciliation", segmentID: nil) {
                let fact = WatchRelayQueueReconciliationFact(
                    at: date,
                    counts: counts,
                    observedFileTransferCount: observedFileTransferCount,
                    activeManifestCount: activeManifestCount
                )
                var summary = await self.diagnosticsSummaryForUpdate()
                summary.lastQueueReconciliationObservation = fact
                try await self.writeDiagnosticsSummary(summary)
            }
        }
    }

    func recordRelayBackgroundWake(
        reason: String,
        heldTaskCount: Int,
        completedTaskCount: Int,
        deadlineCount: Int,
        at date: Date
    ) async {
        _ = await self.withTransaction(.relayDiagnosticsPersistence) {
            await self.performDiagnosticsWrite("background wake", segmentID: nil) {
                let fact = WatchRelayBackgroundWakeFact(
                    at: date,
                    reason: reason,
                    heldTaskCount: heldTaskCount,
                    completedTaskCount: completedTaskCount,
                    deadlineCount: deadlineCount
                )
                var summary = await self.diagnosticsSummaryForUpdate()
                if reason == "deadline" {
                    summary.lastBackgroundWakeDeadline = fact
                } else {
                    summary.lastBackgroundWakeCompletion = fact
                }
                try await self.writeDiagnosticsSummary(summary)
            }
        }
    }

    func readSessionRecord() async throws -> WatchCaptureSessionRecord? {
        try await self.withTransaction(.sessionRecord) {
            let url = self.paths.sessionRecordURL()
            guard await self.fileWriter.fileExists(at: url) else { return nil }
            return try self.manifestDecoder.decode(
                WatchCaptureSessionRecord.self,
                from: try await self.fileWriter.readData(from: url)
            )
        }
    }

    func writeSessionRecord(_ record: WatchCaptureSessionRecord) async throws {
        try await self.withTransaction(.sessionRecord) {
            try await self.fileWriter.atomicReplaceFile(
                at: self.paths.sessionRecordURL(),
                with: self.manifestEncoder.encode(record)
            )
        }
    }

    func readSessionHistory(asOf: Date) async -> WatchCaptureSessionHistoryReadResult {
        await self.withTransaction(.sessionHistory) {
            await self.readSessionHistoryInner(asOf: asOf)
        }
    }

    func sessionHistoryEntry(
        sessionID: String,
        asOf: Date
    ) async -> WatchCaptureSessionHistoryEntry? {
        await self.withTransaction(.sessionHistory) {
            guard case let .available(entries) = await self.readSessionHistoryInner(asOf: asOf) else {
                return nil
            }
            return entries.first { $0.sessionID == sessionID }
        }
    }

    func upsertSessionHistory(
        _ entry: WatchCaptureSessionHistoryEntry,
        asOf: Date
    ) async throws {
        try await self.withTransaction(.sessionHistory) {
            try await self.upsertSessionHistoryInner(entry, asOf: asOf)
        }
    }

    func readSessionHistoryCounter() async -> WatchCaptureSessionHistoryCounter? {
        await self.withTransaction(.sessionHistory) {
            await self.readSessionHistoryCounterInner()
        }
    }

    func incrementLifetimeSessionCounter() async throws -> WatchCaptureSessionHistoryCounter? {
        try await self.withTransaction(.sessionHistory) {
            let url = self.paths.sessionHistoryCounterURL()
            if await self.fileWriter.fileExists(at: url) {
                guard let current = try? self.sessionDecoder.decode(
                    WatchCaptureSessionHistoryCounter.self,
                    from: try await self.fileWriter.readData(from: url)
                ) else {
                    return nil
                }
                let updated = WatchCaptureSessionHistoryCounter(
                    epoch: current.epoch,
                    lifetimeSessionsStarted: current.lifetimeSessionsStarted + 1
                )
                try await self.fileWriter.atomicReplaceFile(at: url, with: self.sessionEncoder.encode(updated))
                return updated
            }
            let counter = WatchCaptureSessionHistoryCounter(epoch: UUID().uuidString, lifetimeSessionsStarted: 1)
            try await self.fileWriter.atomicReplaceFile(at: url, with: self.sessionEncoder.encode(counter))
            return counter
        }
    }

    func revertLifetimeSessionCounterIncrement(
        _ incremented: WatchCaptureSessionHistoryCounter
    ) async throws {
        try await self.withTransaction(.sessionHistory) {
            guard let current = await self.readSessionHistoryCounterInner(),
                  current.epoch == incremented.epoch,
                  current.lifetimeSessionsStarted == incremented.lifetimeSessionsStarted,
                  current.lifetimeSessionsStarted > 0
            else { return }
            let reverted = WatchCaptureSessionHistoryCounter(
                epoch: current.epoch,
                lifetimeSessionsStarted: current.lifetimeSessionsStarted - 1
            )
            try await self.fileWriter.atomicReplaceFile(
                at: self.paths.sessionHistoryCounterURL(),
                with: self.sessionEncoder.encode(reverted)
            )
        }
    }

    func openLocationLogHeader(at url: URL) async throws {
        try await self.withTransaction(.capturePreparation) {
            let data = try self.locationSegmentData(fixCount: 0, gap: true, fixLines: [])
            try await self.fileWriter.writeData(data, to: url, options: .atomic)
        }
    }

    func appendLocationFix(_ fix: WatchLocationFix, at url: URL) async throws {
        try await self.withTransaction(.locationLogAppend) {
            try await self.fileWriter.appendLine(
                try self.locationEncoder.encode(LocationFixLine(fix: fix)),
                to: url
            )
        }
    }

    func finalizeLocationLog(
        at url: URL,
        armed: Bool
    ) async throws -> WatchCaptureLocationLogFinalizedStats {
        try await self.withTransaction(.locationLogReconciliation) {
            let fixLines = try await self.durableLocationFixLines(at: url)
            let stats = WatchCaptureLocationLogFinalizedStats(
                fixCount: fixLines.count,
                gap: armed && fixLines.isEmpty
            )
            try await self.fileWriter.atomicReplaceFile(
                at: url,
                with: try self.locationSegmentData(
                    fixCount: stats.fixCount,
                    gap: stats.gap,
                    fixLines: fixLines
                )
            )
            return stats
        }
    }

    private func scanCatalogInner() async -> WatchCaptureCatalog {
        let rootKind: WatchCaptureStorageItemKind
        do { rootKind = try await self.fileWriter.itemKind(at: self.paths.rootURL) }
        catch { return WatchCaptureCatalog(rootState: .unavailable(.unreadable), entries: [], issues: []) }
        guard rootKind != .missing else {
            return WatchCaptureCatalog(rootState: .unavailable(.missing), entries: [], issues: [])
        }
        guard rootKind == .directory else {
            return WatchCaptureCatalog(rootState: .unavailable(.notDirectory), entries: [], issues: [])
        }
        guard let days = try? await self.fileWriter.contentsOfDirectory(at: self.paths.rootURL) else {
            return WatchCaptureCatalog(rootState: .unavailable(.notEnumerable), entries: [], issues: [])
        }

        var entries: [WatchCaptureCatalogEntry] = []
        var issues: [WatchCaptureCatalogIssue] = []
        for dayURL in days.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let day = dayURL.lastPathComponent
            guard day != ".relay-bundles", day != WatchCaptureStoragePaths.sessionRecordFileName,
                  day != ".relay-diagnostics-summary.json" else { continue }
            let dayKind: WatchCaptureStorageItemKind
            do {
                dayKind = try await self.fileWriter.itemKind(at: dayURL)
            } catch {
                issues.append(self.issue(.fileTypeLookupFailure, namespace: day))
                issues.append(self.issue(.incompleteSubtree, namespace: day))
                continue
            }
            guard dayKind == .directory else {
                issues.append(self.issue(.unexpectedShape, namespace: day))
                continue
            }
            guard let segments = try? await self.fileWriter.contentsOfDirectory(at: dayURL) else {
                issues.append(self.issue(.incompleteSubtree, namespace: day))
                continue
            }
            for segmentURL in segments.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let segment = segmentURL.lastPathComponent
                let id = WatchCaptureCatalogEntryID(day: day, segment: segment)
                let namespace = "\(day)/\(segment)"
                let segmentKind: WatchCaptureStorageItemKind
                do {
                    segmentKind = try await self.fileWriter.itemKind(at: segmentURL)
                } catch {
                    issues.append(self.issue(.fileTypeLookupFailure, namespace: namespace))
                    continue
                }
                guard segmentKind == .directory else {
                    issues.append(self.issue(.unexpectedShape, namespace: namespace))
                    continue
                }
                let manifestURL = self.paths.manifestURL(directory: segmentURL)
                guard await self.fileWriter.fileExists(at: manifestURL) else {
                    issues.append(self.issue(.missingManifest, namespace: namespace))
                    continue
                }
                do {
                    let data = try await self.fileWriter.readData(from: manifestURL)
                    let manifest = try self.manifestDecoder.decode(WatchSegmentManifest.self, from: data)
                    guard manifest.day == day, manifest.segment == segment else {
                        issues.append(self.issue(.pathMismatch, namespace: namespace))
                        continue
                    }
                    entries.append(WatchCaptureCatalogEntry(
                        id: id,
                        directoryURL: segmentURL,
                        manifestURL: manifestURL,
                        manifest: manifest,
                        witness: WatchCaptureContentWitness(
                            manifestData: data,
                            audioBytes: try? await self.fileWriter.fileSize(
                                at: self.paths.audioURL(directory: segmentURL)
                            ),
                            locationBytes: try? await self.fileWriter.fileSize(
                                at: self.paths.locationURL(directory: segmentURL)
                            ),
                            audioFingerprint: try? await self.fileWriter.fileFingerprint(
                                at: self.paths.audioURL(directory: segmentURL)
                            ),
                            locationFingerprint: try? await self.fileWriter.fileFingerprint(
                                at: self.paths.locationURL(directory: segmentURL)
                            )
                        )
                    ))
                } catch {
                    issues.append(self.issue(.manifestDecodeFailure, namespace: namespace))
                }
            }
        }
        let duplicateIDs = Dictionary(grouping: entries, by: { $0.manifest.id }).filter { $0.value.count > 1 }
        if !duplicateIDs.isEmpty {
            for (_, duplicates) in duplicateIDs {
                let namespace = duplicates.map { "\($0.id.day)/\($0.id.segment)" }.sorted().joined(separator: ",")
                issues.append(self.issue(.duplicateManifestUUID, namespace: namespace))
            }
            entries.removeAll { duplicateIDs[$0.manifest.id] != nil }
        }
        let rootState: WatchCaptureCatalogRootState
        if !issues.isEmpty { rootState = .partial }
        else if entries.isEmpty { rootState = .emptyComplete }
        else { rootState = .complete }
        return WatchCaptureCatalog(rootState: rootState, entries: entries, issues: issues.sorted { $0.id < $1.id })
    }

    private func currentRelayEntry(
        _ expected: WatchCaptureCatalogEntry
    ) async throws -> WatchCaptureCatalogEntry {
        guard await self.fileWriter.fileExists(at: expected.manifestURL),
              let manifestData = try? await self.fileWriter.readData(from: expected.manifestURL),
              let manifest = try? self.manifestDecoder.decode(WatchSegmentManifest.self, from: manifestData),
              manifest.id == expected.manifest.id,
              manifest.day == expected.id.day,
              manifest.segment == expected.id.segment
        else {
            throw WatchCaptureStorageConflict.contentWitnessChanged(id: expected.id)
        }
        let witness = await self.contentWitness(
            manifestData: manifestData,
            directoryURL: expected.directoryURL
        )
        return WatchCaptureCatalogEntry(
            id: expected.id,
            directoryURL: expected.directoryURL,
            manifestURL: expected.manifestURL,
            manifest: manifest,
            witness: witness
        )
    }

    private func verifiedRelayEntry(
        _ expected: WatchCaptureCatalogEntry
    ) async throws -> WatchCaptureCatalogEntry {
        let current = try await self.currentRelayEntry(expected)
        try self.verifyRelayWitness(current, against: expected)
        return current
    }

    private func verifyRelayWitness(
        _ current: WatchCaptureCatalogEntry,
        against expected: WatchCaptureCatalogEntry
    ) throws {
        guard current.witness == expected.witness else {
            throw WatchCaptureStorageConflict.contentWitnessChanged(id: expected.id)
        }
    }

    private func writeRelayManifest(
        _ manifest: WatchSegmentManifest,
        replacing entry: WatchCaptureCatalogEntry
    ) async throws -> WatchCaptureCatalogEntry {
        let data = try self.manifestEncoder.encode(manifest)
        try await self.fileWriter.writeData(data, to: entry.manifestURL, options: .atomic)
        return WatchCaptureCatalogEntry(
            id: entry.id,
            directoryURL: entry.directoryURL,
            manifestURL: entry.manifestURL,
            manifest: manifest,
            witness: await self.contentWitness(manifestData: data, directoryURL: entry.directoryURL)
        )
    }

    private func relayBundleData(for entry: WatchCaptureCatalogEntry) async throws -> Data {
        var files: [String: Data] = [:]
        let manifestData = try await self.fileWriter.readData(from: entry.manifestURL)
        guard manifestData == entry.witness.manifestData else {
            throw WatchCaptureStorageConflict.contentWitnessChanged(id: entry.id)
        }
        files[WatchSegmentBundleCodec.manifestFilename] = manifestData

        let audioURL = self.paths.audioURL(directory: entry.directoryURL)
        if await self.fileWriter.fileExists(at: audioURL) {
            files[WatchSegmentBundleCodec.audioFilename] = try await self.fileWriter.readData(from: audioURL)
        }

        let locationURL = self.paths.locationURL(directory: entry.directoryURL)
        if await self.fileWriter.fileExists(at: locationURL) {
            files[WatchSegmentBundleCodec.locationFilename] = try await self.fileWriter.readData(from: locationURL)
        }

        return try PropertyListSerialization.data(
            fromPropertyList: files,
            format: .binary,
            options: 0
        )
    }

    private func contentWitness(
        manifestData: Data,
        directoryURL: URL
    ) async -> WatchCaptureContentWitness {
        WatchCaptureContentWitness(
            manifestData: manifestData,
            audioBytes: try? await self.fileWriter.fileSize(
                at: self.paths.audioURL(directory: directoryURL)
            ),
            locationBytes: try? await self.fileWriter.fileSize(
                at: self.paths.locationURL(directory: directoryURL)
            ),
            audioFingerprint: try? await self.fileWriter.fileFingerprint(
                at: self.paths.audioURL(directory: directoryURL)
            ),
            locationFingerprint: try? await self.fileWriter.fileFingerprint(
                at: self.paths.locationURL(directory: directoryURL)
            )
        )
    }

    private func currentRelayManifest(at directoryURL: URL) async -> (id: UUID, entryID: WatchCaptureCatalogEntryID)? {
        let manifestURL = self.paths.manifestURL(directory: directoryURL)
        guard await self.fileWriter.fileExists(at: manifestURL),
              let data = try? await self.fileWriter.readData(from: manifestURL),
              let manifest = try? self.manifestDecoder.decode(WatchSegmentManifest.self, from: data)
        else {
            return nil
        }
        return (
            manifest.id,
            WatchCaptureCatalogEntryID(day: manifest.day, segment: manifest.segment)
        )
    }

    private func verifiedRelayDeletionEntry(
        _ expected: WatchCaptureCatalogEntry
    ) async throws -> WatchCaptureCatalogEntry {
        do {
            return try await self.verifiedRelayEntry(expected)
        } catch WatchCaptureStorageConflict.contentWitnessChanged {
            let found = await self.currentRelayManifest(at: expected.directoryURL)
            guard found?.entryID == expected.id, found?.id == expected.manifest.id else {
                throw WatchCaptureStorageConflict.staleAcknowledgementReplacement(
                    id: expected.manifest.id,
                    expected: expected.id,
                    found: found?.entryID
                )
            }
            throw WatchCaptureStorageConflict.contentWitnessChanged(id: expected.id)
        }
    }

    private func performDiagnosticsWrite(
        _ label: String,
        segmentID: UUID?,
        _ body: () async throws -> Void
    ) async -> Bool {
        do {
            try await body()
            return true
        } catch {
            self.diagnosticsUnavailableAfterWriteFailure = true
            let id = segmentID?.uuidString ?? "none"
            watchRelayDiagnosticsLog.error(
                "watch relay diagnostic \(label, privacy: .public) write failed id=\(id, privacy: .public): \(String(describing: error), privacy: .private)"
            )
            return false
        }
    }

    private func diagnosticsSidecarForUpdate(
        manifest: WatchSegmentManifest,
        directoryURL: URL
    ) async -> WatchRelaySegmentDiagnosticsSidecar {
        let url = WatchRelayDiagnosticsFiles.sidecarURL(directoryURL: directoryURL)
        guard await self.fileWriter.fileExists(at: url) else {
            return WatchRelaySegmentDiagnosticsSidecar(segmentID: manifest.id)
        }
        do {
            return try await self.decodeDiagnosticsSidecar(from: url, expectedID: manifest.id)
        } catch {
            await self.resetCorruptDiagnosticFile(at: url, error: error)
            return WatchRelaySegmentDiagnosticsSidecar(segmentID: manifest.id)
        }
    }

    private func diagnosticsSummaryForUpdate() async -> WatchRelayDiagnosticsSummaryFile {
        let url = WatchRelayDiagnosticsFiles.summaryURL(rootURL: self.paths.rootURL)
        guard await self.fileWriter.fileExists(at: url) else { return .empty }
        do {
            return try await self.decodeDiagnosticsSummary(from: url)
        } catch {
            await self.resetCorruptDiagnosticFile(at: url, error: error)
            return .empty
        }
    }

    private func diagnosticsSourceByteSize(at url: URL, sourcePresent: Bool) async -> Int64? {
        guard sourcePresent else { return nil }
        return try? await self.fileWriter.fileSize(at: url)
    }

    private func decodeDiagnosticsSidecar(
        from url: URL,
        expectedID: UUID
    ) async throws -> WatchRelaySegmentDiagnosticsSidecar {
        let sidecar = try self.diagnosticsDecoder.decode(
            WatchRelaySegmentDiagnosticsSidecar.self,
            from: try await self.fileWriter.readData(from: url)
        )
        guard sidecar.version <= WatchRelaySegmentDiagnosticsSidecar.currentVersion,
              sidecar.segmentID == expectedID
        else {
            throw WatchRelayDiagnosticsStoreError.unsupportedOrMismatchedSidecar
        }
        try Self.validateDiagnosticsSidecarInvariants(sidecar)
        return sidecar
    }

    private func decodeDiagnosticsSummary(from url: URL) async throws -> WatchRelayDiagnosticsSummaryFile {
        let summary = try self.diagnosticsDecoder.decode(
            WatchRelayDiagnosticsSummaryFile.self,
            from: try await self.fileWriter.readData(from: url)
        )
        guard summary.version <= WatchRelayDiagnosticsSummaryFile.currentVersion else {
            throw WatchRelayDiagnosticsStoreError.unsupportedSummary
        }
        try Self.validateDiagnosticsSummaryInvariants(summary)
        return summary
    }

    private func writeDiagnosticsSidecar(
        _ sidecar: WatchRelaySegmentDiagnosticsSidecar,
        directoryURL: URL
    ) async throws {
        try await self.fileWriter.writeData(
            try self.diagnosticsEncoder.encode(sidecar),
            to: WatchRelayDiagnosticsFiles.sidecarURL(directoryURL: directoryURL),
            options: .atomic
        )
    }

    private func writeDiagnosticsSummary(_ summary: WatchRelayDiagnosticsSummaryFile) async throws {
        try await self.fileWriter.writeData(
            try self.diagnosticsEncoder.encode(summary),
            to: WatchRelayDiagnosticsFiles.summaryURL(rootURL: self.paths.rootURL),
            options: .atomic
        )
    }

    private func resetCorruptDiagnosticFile(at url: URL, error: any Error) async {
        let key = url.standardizedFileURL.path
        if self.loggedCorruptDiagnosticURLs.insert(key).inserted {
            watchRelayDiagnosticsLog.error(
                "watch relay diagnostic file reset path=\(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
        try? await self.fileWriter.removeItem(at: url)
    }

    private static func incrementDiagnosticsCounter(_ current: Int) throws -> Int {
        let (next, overflow) = max(0, current).addingReportingOverflow(1)
        guard !overflow, next < Int.max else {
            throw WatchRelayDiagnosticsStoreError.counterOverflow
        }
        return next
    }

    private static func validateDiagnosticsSidecarInvariants(
        _ sidecar: WatchRelaySegmentDiagnosticsSidecar
    ) throws {
        try self.validateDiagnosticsCounter(sidecar.attemptCount)
        if let sourceBytes = sidecar.sourceBytes {
            try self.validateDiagnosticsNonNegative(sourceBytes)
        }
        try self.validateDiagnosticsSegmentLastFacts(sidecar.lastFacts)
    }

    private static func validateDiagnosticsSummaryInvariants(
        _ summary: WatchRelayDiagnosticsSummaryFile
    ) throws {
        try self.validateDiagnosticsFactCounter(summary.lastEnqueue)
        try self.validateDiagnosticsTransferCompletion(summary.lastTransferCompletion)
        try self.validateDiagnosticsFactCounter(summary.lastDurableACK)
        try self.validateDiagnosticsQueueReconciliation(summary.lastQueueReconciliationObservation)
        try self.validateDiagnosticsBackgroundWake(summary.lastBackgroundWakeCompletion)
        try self.validateDiagnosticsBackgroundWake(summary.lastBackgroundWakeDeadline)
    }

    private static func validateDiagnosticsSegmentLastFacts(_ facts: WatchRelaySegmentLastFacts) throws {
        try self.validateDiagnosticsFactCounter(facts.lastEnqueue)
        try self.validateDiagnosticsTransferCompletion(facts.lastTransferCompletion)
        try self.validateDiagnosticsFactCounter(facts.lastDurableACK)
        try self.validateDiagnosticsQueueReconciliation(facts.lastQueueReconciliationObservation)
    }

    private static func validateDiagnosticsFactCounter(_ fact: WatchRelayFactCounter?) throws {
        guard let fact else { return }
        try self.validateDiagnosticsCounter(fact.count)
    }

    private static func validateDiagnosticsTransferCompletion(
        _ fact: WatchRelayTransferCompletionFact?
    ) throws {
        guard let fact else { return }
        try self.validateDiagnosticsCounter(fact.successCount)
        try self.validateDiagnosticsCounter(fact.failureCount)
    }

    private static func validateDiagnosticsQueueReconciliation(
        _ fact: WatchRelayQueueReconciliationFact?
    ) throws {
        guard let fact else { return }
        try self.validateDiagnosticsReconciliationCounts(fact.counts)
        try self.validateDiagnosticsCounter(fact.observedFileTransferCount)
        try self.validateDiagnosticsCounter(fact.activeManifestCount)
    }

    private static func validateDiagnosticsReconciliationCounts(
        _ counts: WatchRelayReconciliationCounts
    ) throws {
        try self.validateDiagnosticsCounter(counts.matched)
        try self.validateDiagnosticsCounter(counts.appActiveNotObserved)
        try self.validateDiagnosticsCounter(counts.duplicate)
        try self.validateDiagnosticsCounter(counts.orphaned)
        try self.validateDiagnosticsCounter(counts.unparseable)
    }

    private static func validateDiagnosticsBackgroundWake(_ fact: WatchRelayBackgroundWakeFact?) throws {
        guard let fact else { return }
        try self.validateDiagnosticsCounter(fact.heldTaskCount)
        try self.validateDiagnosticsCounter(fact.completedTaskCount)
        try self.validateDiagnosticsCounter(fact.deadlineCount)
    }

    private static func validateDiagnosticsCounter(_ value: Int) throws {
        guard value >= 0, value < Int.max else {
            throw WatchRelayDiagnosticsStoreError.invalidNumericInvariant
        }
    }

    private static func validateDiagnosticsNonNegative(_ value: Int64) throws {
        guard value >= 0 else {
            throw WatchRelayDiagnosticsStoreError.invalidNumericInvariant
        }
    }

    private func staleState(
        _ entry: WatchCaptureCatalogEntry,
        expected: WatchSegmentState,
        actual: WatchSegmentState
    ) -> WatchCaptureStorageConflict {
        .staleQueuedSnapshot(id: entry.manifest.id, expected: expected, actual: actual)
    }

    private func readSessionHistoryInner(asOf: Date) async -> WatchCaptureSessionHistoryReadResult {
        let parsed = await self.readParsedSessionHistoryEntries()
        guard parsed.fileExists else { return .available([]) }
        let entries = self.prunedSessionHistoryEntries(parsed.entries, asOf: asOf)
        if entries.count != parsed.entries.count {
            do {
                try await self.writeSessionHistory(entries: entries, unreadableLines: parsed.unreadableLines)
            } catch {
                return .unreadable
            }
        }
        guard !parsed.hadDamage || !entries.isEmpty else { return .unreadable }
        return .available(entries)
    }

    private func locationSegmentData(
        fixCount: Int,
        gap: Bool,
        fixLines: [Data]
    ) throws -> Data {
        var data = Data()
        data.append(try self.locationEncoder.encode(LocationHeaderLine(fixCount: fixCount, gap: gap)))
        data.append(0x0A)
        for line in fixLines {
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    private func durableLocationFixLines(at url: URL) async throws -> [Data] {
        guard await self.fileWriter.fileExists(at: url) else { return [] }
        let data = try await self.fileWriter.readData(from: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > 1 else { return [] }
        return lines.dropFirst().map { Data($0) }
    }

    private func upsertSessionHistoryInner(
        _ entry: WatchCaptureSessionHistoryEntry,
        asOf: Date
    ) async throws {
        let parsed = await self.readParsedSessionHistoryEntries()
        var entriesByID = Dictionary(uniqueKeysWithValues: parsed.entries.map { ($0.sessionID, $0) })
        entriesByID[entry.sessionID] = entry
        let entries = self.prunedSessionHistoryEntries(Array(entriesByID.values), asOf: asOf)
            .sorted { $0.startedAt < $1.startedAt }
        try await self.writeSessionHistory(entries: entries, unreadableLines: parsed.unreadableLines)
    }

    private func readSessionHistoryCounterInner() async -> WatchCaptureSessionHistoryCounter? {
        let url = self.paths.sessionHistoryCounterURL()
        guard await self.fileWriter.fileExists(at: url) else { return nil }
        guard let data = try? await self.fileWriter.readData(from: url) else { return nil }
        return try? self.sessionDecoder.decode(WatchCaptureSessionHistoryCounter.self, from: data)
    }

    private func writeSessionHistory(
        entries: [WatchCaptureSessionHistoryEntry],
        unreadableLines: [Data]
    ) async throws {
        var data = Data()
        for entry in entries {
            data.append(try self.sessionEncoder.encode(entry))
            data.append(0x0A)
        }
        // Preserve malformed source lines for diagnosis; a damaged tail must never turn into a silent reset.
        for line in unreadableLines {
            data.append(line)
            data.append(0x0A)
        }
        try await self.fileWriter.atomicReplaceFile(at: self.paths.sessionHistoryURL(), with: data)
    }

    private func readParsedSessionHistoryEntries() async -> (
        entries: [WatchCaptureSessionHistoryEntry],
        unreadableLines: [Data],
        hadDamage: Bool,
        fileExists: Bool
    ) {
        let url = self.paths.sessionHistoryURL()
        guard await self.fileWriter.fileExists(at: url) else {
            return ([], [], false, false)
        }
        guard let data = try? await self.fileWriter.readData(from: url) else {
            return ([], [], true, true)
        }
        var newestByID: [String: WatchCaptureSessionHistoryEntry] = [:]
        var unreadableLines: [Data] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            if let entry = try? self.sessionDecoder.decode(WatchCaptureSessionHistoryEntry.self, from: lineData) {
                newestByID[entry.sessionID] = entry
            } else {
                unreadableLines.append(lineData)
            }
        }
        return (Array(newestByID.values), unreadableLines, !unreadableLines.isEmpty, true)
    }

    private func prunedSessionHistoryEntries(
        _ entries: [WatchCaptureSessionHistoryEntry],
        asOf: Date
    ) -> [WatchCaptureSessionHistoryEntry] {
        let cutoff = asOf.addingTimeInterval(-Self.sessionHistoryRetention)
        return entries
            .filter { $0.terminalAt ?? $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Self.maximumSessionHistoryEntryCount)
            .map { $0 }
    }

    private struct LocationHeaderLine: Encodable {
        let fixCount: Int
        let gap: Bool

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case source
            case platform
            case tier
            case accuracy
            case fixCount = "fix_count"
            case gap
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.segment/1", forKey: .schema)
            try container.encode("location", forKey: .kind)
            try container.encode("location", forKey: .source)
            try container.encode("watchos", forKey: .platform)
            try container.encode("light", forKey: .tier)
            try container.encode("reduced", forKey: .accuracy)
            try container.encode(self.fixCount, forKey: .fixCount)
            try container.encode(self.gap, forKey: .gap)
        }
    }

    private struct LocationFixLine: Encodable {
        let fix: WatchLocationFix

        enum CodingKeys: String, CodingKey {
            case schema
            case t
            case lat
            case lon
            case hAcc = "h_acc"
            case alt
            case vAcc = "v_acc"
            case speed
            case course
            case stationary
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.fix/1", forKey: .schema)
            try container.encode(self.fix.t, forKey: .t)
            try container.encode(self.fix.lat, forKey: .lat)
            try container.encode(self.fix.lon, forKey: .lon)
            try container.encode(self.fix.hAcc, forKey: .hAcc)
            if let alt = self.fix.alt {
                try container.encode(alt, forKey: .alt)
            } else {
                try container.encodeNil(forKey: .alt)
            }
            if let vAcc = self.fix.vAcc {
                try container.encode(vAcc, forKey: .vAcc)
            } else {
                try container.encodeNil(forKey: .vAcc)
            }
            if let speed = self.fix.speed {
                try container.encode(speed, forKey: .speed)
            } else {
                try container.encodeNil(forKey: .speed)
            }
            if let course = self.fix.course {
                try container.encode(course, forKey: .course)
            } else {
                try container.encodeNil(forKey: .course)
            }
            try container.encode(self.fix.stationary, forKey: .stationary)
        }
    }

    private func issue(_ kind: WatchCaptureCatalogIssueKind, namespace: String) -> WatchCaptureCatalogIssue {
        WatchCaptureCatalogIssue(id: "\(kind.rawValue):\(namespace)", kind: kind, namespace: namespace)
    }

    private func prepareRootInner() async throws {
        try await self.fileWriter.createDirectory(at: self.paths.rootURL)
    }

    private func withTransaction<Value: Sendable>(
        _ boundary: WatchSignpostBoundary = .storageActorFileOperation,
        _ body: @escaping @isolated(any) () async throws -> Value
    ) async rethrows -> Value {
        await self.acquireTransaction()
        // This measures the gate-admitted storage transaction, not MainActor occupancy.
        // In particular, queue wait ends before the interval begins.
        let invocation = self.storageSignposter.begin(boundary)
        defer {
            self.storageSignposter.end(invocation)
            self.releaseTransaction()
        }
        return try await body()
    }

    private func acquireTransaction() async {
        guard self.transactionIsActive else {
            self.transactionIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            self.transactionWaiters.append(continuation)
        }
    }

    private func releaseTransaction() {
        if self.transactionWaiters.isEmpty {
            self.transactionIsActive = false
        } else {
            self.transactionWaiters.removeFirst().resume()
        }
    }
}
