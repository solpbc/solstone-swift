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

    var hasCompleteMediaEvidence: Bool {
        self.audioBytes != nil && self.locationBytes != nil
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
    let relevantMutationGeneration: UInt64

    var canInferUUIDAbsence: Bool { self.rootState.canInferUUIDAbsence }

    func replacingEntry(_ entry: WatchCaptureCatalogEntry) -> WatchCaptureCatalog {
        var entries = self.entries
        if let index = entries.firstIndex(where: { $0.manifest.id == entry.manifest.id }) {
            entries[index] = entry
        }
        return WatchCaptureCatalog(
            rootState: self.rootState,
            entries: entries,
            issues: self.issues,
            relevantMutationGeneration: self.relevantMutationGeneration
        )
    }

    func removingEntry(manifestID: UUID) -> WatchCaptureCatalog {
        WatchCaptureCatalog(
            rootState: self.rootState,
            entries: self.entries.filter { $0.manifest.id != manifestID },
            issues: self.issues,
            relevantMutationGeneration: self.relevantMutationGeneration
        )
    }

    func withRelevantMutationGeneration(_ generation: UInt64) -> WatchCaptureCatalog {
        WatchCaptureCatalog(
            rootState: self.rootState,
            entries: self.entries,
            issues: self.issues,
            relevantMutationGeneration: generation
        )
    }
}

nonisolated enum WatchCaptureStorageConflict: Error, Equatable, Sendable {
    case staleRelayState(id: UUID, expected: WatchSegmentState, actual: WatchSegmentState)
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

nonisolated enum WatchRelayCleanupRemoval: Sendable {
    case removed
    case retained(WatchCaptureCatalogEntry)
}

nonisolated enum WatchComplicationSnapshotWriteOutcome: Equatable, Sendable {
    case written
    case unchanged
}

nonisolated struct WatchRelayTransferPreparation: Sendable {
    let bundleURL: URL
    let manifest: WatchSegmentManifest
    let attempt: WatchRelayAttemptRecord?
    let bundleCleanupFailed: Bool
    let attemptCleanupFailed: Bool
    let attemptFailure: WatchConnectivityTransferFailureSnapshot?
}

nonisolated enum WatchCaptureStorageTransactionClass: Sendable {
    case captureSafety
    case maintenance
}

nonisolated struct WatchCaptureTerminalTuple: Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    let reason: WatchCaptureTerminalReason?
    let disposition: WatchCaptureTerminalDisposition?
    let terminalAt: Date?
    let noticeOwed: Bool

    init(
        sessionID: String,
        startedAt: Date,
        reason: WatchCaptureTerminalReason?,
        disposition: WatchCaptureTerminalDisposition?,
        terminalAt: Date?,
        noticeOwed: Bool
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.reason = reason
        self.disposition = disposition
        self.terminalAt = terminalAt
        self.noticeOwed = noticeOwed
    }
}

nonisolated enum WatchCaptureTerminalTupleResolution: Equatable, Sendable {
    case resolvedAndPersisted(WatchCaptureTerminalTuple)
    case failClosed
}

nonisolated struct WatchCaptureTerminalNoticeMetadata: Equatable, Sendable {
    let noticeOwed: Bool?
    let noticeDecision: String?
    let noticeDelivered: Bool?
    let notificationAuthorizationStatus: WatchNotificationAuthorizationStatus?
    let notificationAlertSetting: WatchNotificationAlertSetting?
    let wristAlertAssurance: WatchWristAlertAssurance?
    let settingsRoute: WatchCaptureSettingsRoute?

    init(
        noticeOwed: Bool? = nil,
        noticeDecision: String? = nil,
        noticeDelivered: Bool? = nil,
        notificationAuthorizationStatus: WatchNotificationAuthorizationStatus? = nil,
        notificationAlertSetting: WatchNotificationAlertSetting? = nil,
        wristAlertAssurance: WatchWristAlertAssurance? = nil,
        settingsRoute: WatchCaptureSettingsRoute? = nil
    ) {
        self.noticeOwed = noticeOwed
        self.noticeDecision = noticeDecision
        self.noticeDelivered = noticeDelivered
        self.notificationAuthorizationStatus = notificationAuthorizationStatus
        self.notificationAlertSetting = notificationAlertSetting
        self.wristAlertAssurance = wristAlertAssurance
        self.settingsRoute = settingsRoute
    }
}

/// The Watch app's single owner for durable capture files and catalog reads.
/// Its initializer intentionally only receives paths; root creation is delayed until a mutation.
actor WatchCaptureStorageActor {
    private struct TransactionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

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
    // Tests use this only to make a synchronous actor-work span long enough to observe.
    // The production default is a no-op and is skipped while signposting is disabled.
    private let synchronousWorkHook: @Sendable (WatchSignpostBoundary) -> Void
    private var transactionIsActive = false
    private var captureSafetyWaiters: [TransactionWaiter] = []
    private var maintenanceWaiters: [TransactionWaiter] = []
    private var transactionAdmissionCount = 0
    private var relevantMutationGeneration: UInt64 = 0
    private var loggedCorruptDiagnosticURLs: Set<String> = []
    private var diagnosticsUnavailableAfterWriteFailure = false

    init(
        paths: WatchCaptureStoragePaths,
        fileWriter: any WatchFileWriting,
        audioProbe: any WatchAudioProbing = LiveWatchAudioProbe(),
        storageSignposter: WatchStorageSignposter = WatchStorageSignposter(),
        synchronousWorkHook: @escaping @Sendable (WatchSignpostBoundary) -> Void = { _ in }
    ) {
        self.paths = paths
        self.fileWriter = fileWriter
        self.audioProbe = audioProbe
        self.storageSignposter = storageSignposter
        self.synchronousWorkHook = synchronousWorkHook
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

    func currentRelevantMutationGeneration() -> UInt64 {
        self.relevantMutationGeneration
    }

    func needsCatalogFallbackRescan(snapshot: WatchCaptureCatalog, successfulBumps: UInt64) -> Bool {
        !snapshot.canInferUUIDAbsence
            || self.relevantMutationGeneration != snapshot.relevantMutationGeneration &+ successfulBumps
    }

    func prepareRoot() async throws {
        try await self.withTransaction(transactionClass: .captureSafety) {
            let rootURL = self.withSynchronousActorWork(.capturePreparation) {
                self.paths.rootURL
            }
            try await self.fileWriter.createDirectory(at: rootURL)
            self.bumpRelevantMutationGeneration()
        }
    }

    func prepareSegmentDirectory(day: String, segment: String) async throws -> URL {
        try await self.withTransaction(transactionClass: .captureSafety) {
            let directory = self.withSynchronousActorWork(.capturePreparation) {
                self.paths.segmentDirectoryURL(day: day, segment: segment)
            }
            let exists = await self.fileWriter.fileExists(at: directory)
            try self.withSynchronousActorWork(.capturePreparation) {
                guard !exists else {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteFileExistsError,
                        userInfo: [NSFilePathErrorKey: directory.path]
                    )
                }
            }
            try await self.fileWriter.createDirectory(at: directory)
            self.bumpRelevantMutationGeneration()
            return directory
        }
    }

    func moveSegmentDirectoryIfNeeded(
        currentURL: URL,
        day: String,
        currentSegment: String,
        finalSegment: String
    ) async throws -> URL {
        try await self.withTransaction(transactionClass: .captureSafety) {
            let finalURL = self.withSynchronousActorWork(.captureFinalization) { () -> URL? in
                guard currentSegment != finalSegment else { return nil }
                return self.paths.segmentDirectoryURL(day: day, segment: finalSegment)
            }
            guard let finalURL else { return currentURL }
            try await self.fileWriter.moveItem(at: currentURL, to: finalURL)
            self.bumpRelevantMutationGeneration()
            return finalURL
        }
    }

    func fileExists(
        at url: URL,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async -> Bool {
        await self.withTransaction(transactionClass: transactionClass) {
            let fileURL = self.withSynchronousActorWork(.storageActorFileOperation) { url }
            return await self.fileWriter.fileExists(at: fileURL)
        }
    }

    func fileSize(
        at url: URL,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async throws -> Int64 {
        try await self.withTransaction(transactionClass: transactionClass) {
            let fileURL = self.withSynchronousActorWork(.storageActorFileOperation) { url }
            return try await self.fileWriter.fileSize(at: fileURL)
        }
    }

    func removeItem(
        at url: URL,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async throws {
        try await self.withTransaction(transactionClass: transactionClass) {
            let fileURL = self.withSynchronousActorWork(.storageActorFileOperation) { url }
            try await self.fileWriter.removeItem(at: fileURL)
            self.bumpRelevantMutationGeneration()
        }
    }

    @discardableResult
    func writeComplicationSnapshot(_ data: Data, to url: URL) async throws -> WatchComplicationSnapshotWriteOutcome {
        try await self.withTransaction(transactionClass: .maintenance) {
            let snapshot = self.withSynchronousActorWork(.complicationSnapshot) { (data, url) }
            if let existing = try? await self.fileWriter.readData(from: snapshot.1), existing == snapshot.0 {
                return .unchanged
            }
            try await self.fileWriter.writeData(snapshot.0, to: snapshot.1, options: .atomic)
            self.bumpRelevantMutationGeneration()
            return .written
        }
    }

    func removeSegmentDirectoryIfMediaIsProvablyEmpty(at directory: URL) async -> Bool {
        await self.withTransaction(transactionClass: .captureSafety) {
            let mediaURLs = self.withSynchronousActorWork(.captureFinalization) {
                [
                    self.paths.audioURL(directory: directory),
                    self.paths.locationURL(directory: directory),
                ]
            }
            for url in mediaURLs {
                do {
                    let size = try await self.fileWriter.fileSize(at: url)
                    let isEmpty = self.withSynchronousActorWork(.captureFinalization) { size == 0 }
                    guard isEmpty else { return false }
                } catch {
                    return false
                }
            }
            do {
                try await self.fileWriter.removeItem(at: directory)
                self.bumpRelevantMutationGeneration()
                return true
            } catch {
                return false
            }
        }
    }

    func probeAudio(at url: URL) async -> WatchAudioProbeResult {
        await self.withTransaction(transactionClass: .captureSafety) {
            let audioURL = self.withSynchronousActorWork(.captureFinalization) { url }
            do {
                _ = try await self.fileWriter.readData(from: audioURL)
            } catch {
                return self.withSynchronousActorWork(.captureFinalization) { .ioUnknown }
            }
            return await self.audioProbe.probe(at: audioURL)
        }
    }

    func scanCatalog(
        transactionClass: WatchCaptureStorageTransactionClass
    ) async -> WatchCaptureCatalog {
        await self.scanCatalogInner(
            transactionClass: transactionClass,
            boundary: .manifestScan
        )
    }

    @discardableResult
    func writeManifest(
        _ manifest: WatchSegmentManifest,
        entry: WatchCaptureCatalogEntry? = nil,
        ensuringDirectory: Bool = true,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async throws -> WatchCaptureCatalogEntry {
        switch transactionClass {
        case .captureSafety:
            return try await self.withTransaction(transactionClass: transactionClass) {
                let written = try await self.writeManifestInner(
                    manifest,
                    entry: entry,
                    ensuringDirectory: ensuringDirectory
                )
                self.bumpRelevantMutationGeneration()
                return written
            }
        case .maintenance:
            return try await self.withCancellableTransaction(transactionClass: transactionClass) {
                let written = try await self.writeManifestInner(
                    manifest,
                    entry: entry,
                    ensuringDirectory: ensuringDirectory
                )
                self.bumpRelevantMutationGeneration()
                return written
            }
        }
    }

    func promoteQueuedForRelay(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.currentRelayEntry(entry, boundary: .relaySegmentTransition)
            let manifest = try self.withSynchronousActorWork(.relaySegmentTransition) { () -> WatchSegmentManifest in
                guard current.manifest.state == .queued else {
                    throw self.staleState(entry, expected: .queued, actual: current.manifest.state)
                }
                try self.verifyRelayWitness(current, against: entry)
                var manifest = current.manifest
                manifest.state = .transferring
                return manifest
            }
            return WatchRelayStorageTransition(
                entry: try await self.writeRelayManifest(manifest, replacing: current, boundary: .relaySegmentTransition),
                didChange: true
            )
        }
    }

    func adoptQueuedForRelay(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.currentRelayEntry(entry, boundary: .relaySegmentTransition)
            switch current.manifest.state {
            case .queued:
                let manifest = try self.withSynchronousActorWork(.relaySegmentTransition) { () -> WatchSegmentManifest in
                    try self.verifyRelayWitness(current, against: entry)
                    var manifest = current.manifest
                    manifest.state = .transferring
                    return manifest
                }
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current, boundary: .relaySegmentTransition),
                    didChange: true
                )
            case .transferring:
                return try self.withSynchronousActorWork(.relaySegmentTransition) {
                    try self.verifyRelayWitness(current, against: entry)
                    return WatchRelayStorageTransition(entry: current, didChange: false)
                }
            default:
                throw self.withSynchronousActorWork(.relaySegmentTransition) {
                    self.staleState(entry, expected: .queued, actual: current.manifest.state)
                }
            }
        }
    }

    func requeueFailedRelayTransfer(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.currentRelayEntry(entry, boundary: .relaySegmentTransition)
            switch current.manifest.state {
            case .transferring:
                let manifest = try self.withSynchronousActorWork(.relaySegmentTransition) { () -> WatchSegmentManifest in
                    try self.verifyRelayWitness(current, against: entry)
                    var manifest = current.manifest
                    manifest.state = .queued
                    return manifest
                }
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current, boundary: .relaySegmentTransition),
                    didChange: true
                )
            case .queued:
                return try self.withSynchronousActorWork(.relaySegmentTransition) {
                    try self.verifyRelayWitness(current, against: entry)
                    return WatchRelayStorageTransition(entry: current, didChange: false)
                }
            default:
                throw self.withSynchronousActorWork(.relaySegmentTransition) {
                    self.staleState(entry, expected: .transferring, actual: current.manifest.state)
                }
            }
        }
    }

    func markRelayTransferDelivered(
        _ entry: WatchCaptureCatalogEntry,
        at deliveredAt: Date
    ) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.currentRelayEntry(entry, boundary: .relaySegmentTransition)
            switch current.manifest.state {
            case .transferring, .queued:
                let manifest = try self.withSynchronousActorWork(.relaySegmentTransition) { () -> WatchSegmentManifest in
                    try self.verifyRelayWitness(current, against: entry)
                    var manifest = current.manifest
                    manifest.state = .delivered
                    manifest.deliveredAt = deliveredAt
                    return manifest
                }
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current, boundary: .relaySegmentTransition),
                    didChange: true
                )
            case .delivered:
                return try self.withSynchronousActorWork(.relaySegmentTransition) {
                    try self.verifyRelayWitness(current, against: entry)
                    return WatchRelayStorageTransition(entry: current, didChange: false)
                }
            default:
                throw self.withSynchronousActorWork(.relaySegmentTransition) {
                    self.staleState(entry, expected: entry.manifest.state, actual: current.manifest.state)
                }
            }
        }
    }

    func acknowledgeRelaySegment(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.verifiedRelayEntry(entry, boundary: .relaySegmentTransition)
            switch current.manifest.state {
            case .acked, .safeToDelete:
                return self.withSynchronousActorWork(.relaySegmentTransition) {
                    WatchRelayStorageTransition(entry: current, didChange: false)
                }
            default:
                let manifest = self.withSynchronousActorWork(.relaySegmentTransition) { () -> WatchSegmentManifest in
                    var manifest = current.manifest
                    manifest.state = .acked
                    return manifest
                }
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current, boundary: .relaySegmentTransition),
                    didChange: true
                )
            }
        }
    }

    func markRelaySegmentSafeToDelete(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.currentRelayEntry(entry, boundary: .relaySegmentTransition)
            switch current.manifest.state {
            case .acked:
                let manifest = try self.withSynchronousActorWork(.relaySegmentTransition) { () -> WatchSegmentManifest in
                    try self.verifyRelayWitness(current, against: entry)
                    var manifest = current.manifest
                    manifest.state = .safeToDelete
                    return manifest
                }
                return WatchRelayStorageTransition(
                    entry: try await self.writeRelayManifest(manifest, replacing: current, boundary: .relaySegmentTransition),
                    didChange: true
                )
            case .safeToDelete:
                return try self.withSynchronousActorWork(.relaySegmentTransition) {
                    try self.verifyRelayWitness(current, against: entry)
                    return WatchRelayStorageTransition(entry: current, didChange: false)
                }
            default:
                throw self.withSynchronousActorWork(.relaySegmentTransition) {
                    self.staleState(entry, expected: .acked, actual: current.manifest.state)
                }
            }
        }
    }

    func deleteAcknowledgedRelaySegment(
        _ entry: WatchCaptureCatalogEntry,
        bundleURL: URL
    ) async throws {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.verifiedRelayDeletionEntry(entry, boundary: .relayCleanupScan)
            try self.withSynchronousActorWork(.relayCleanupScan) {
                guard current.manifest.state == .safeToDelete else {
                    throw self.staleState(entry, expected: .safeToDelete, actual: current.manifest.state)
                }
            }
            try await self.fileWriter.removeItem(at: current.directoryURL)
            try? await self.fileWriter.removeItem(at: bundleURL)
            self.bumpRelevantMutationGeneration()
        }
    }

    func refreshRelayDeliveredDeadline(
        _ entry: WatchCaptureCatalogEntry,
        at now: Date,
        deadline: TimeInterval
    ) async throws -> WatchRelayStorageTransition {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.currentRelayEntry(entry, boundary: .relaySegmentTransition)
            let transition = try self.withSynchronousActorWork(.relaySegmentTransition) { () -> WatchSegmentManifest? in
                guard current.manifest.state == .delivered else {
                    throw self.staleState(entry, expected: .delivered, actual: current.manifest.state)
                }
                try self.verifyRelayWitness(current, against: entry)
                var manifest = current.manifest
                guard let deliveredAt = manifest.deliveredAt else {
                    manifest.deliveredAt = now
                    return manifest
                }
                guard now.timeIntervalSince(deliveredAt) >= deadline else { return nil }
                manifest.state = .queued
                manifest.deliveredAt = nil
                return manifest
            }
            guard let transition else {
                return WatchRelayStorageTransition(entry: current, didChange: false)
            }
            return WatchRelayStorageTransition(
                entry: try await self.writeRelayManifest(transition, replacing: current, boundary: .relaySegmentTransition),
                didChange: true
            )
        }
    }

    func prepareRelayTransfer(
        _ entry: WatchCaptureCatalogEntry,
        bundleURL: URL,
        attempt: WatchRelayAttemptRecord
    ) async throws -> WatchRelayTransferPreparation {
        try await self.withTransaction(transactionClass: .maintenance) {
            let current = try await self.currentRelayEntry(entry, boundary: .relayBundleWrite)
            try self.withSynchronousActorWork(.relayBundleWrite) {
                guard current.manifest.state == .transferring else {
                    throw self.staleState(entry, expected: .transferring, actual: current.manifest.state)
                }
                try self.verifyRelayWitness(current, against: entry)
            }

            var bundleCleanupFailed = false
            do {
                try await self.fileWriter.removeItem(at: bundleURL)
            } catch {
                bundleCleanupFailed = true
            }
            let bundleData = try await self.relayBundleData(for: current, boundary: .relayBundleWrite)
            try await self.fileWriter.writeData(bundleData, to: bundleURL, options: .atomic)
            self.bumpRelevantMutationGeneration()

            let attemptURL = self.withSynchronousActorWork(.relayAttemptPersistence) {
                current.directoryURL.appendingPathComponent(WatchRelayAttemptRecord.filename, isDirectory: false)
            }
            do {
                let attemptData = try self.withSynchronousActorWork(.relayAttemptPersistence) {
                    try WatchRelayAttemptRecord.makeEncoder().encode(attempt)
                }
                try await self.fileWriter.writeData(
                    attemptData,
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
                let failure = self.withSynchronousActorWork(.relayAttemptPersistence) {
                    WatchConnectivityTransferFailureSnapshot(error: error)
                }
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
        await self.withTransaction(transactionClass: .maintenance) {
            let preflight = self.withSynchronousActorWork(.diagnosticsHistorySummaryRead) {
                (
                    self.diagnosticsUnavailableAfterWriteFailure,
                    WatchRelayDiagnosticsFiles.sidecarURL(directoryURL: directoryURL)
                )
            }
            guard !preflight.0 else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            let url = preflight.1
            guard await self.fileWriter.fileExists(at: url) else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            do {
                return .available(try await self.decodeDiagnosticsSidecar(
                    from: url,
                    expectedID: manifest.id,
                    boundary: .diagnosticsHistorySummaryRead
                ))
            } catch {
                await self.resetCorruptDiagnosticFile(
                    at: url,
                    error: error,
                    boundary: .diagnosticsHistorySummaryRead
                )
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
        }
    }

    func readDiagnosticsSummary() async -> DiagnosticAvailability<WatchRelayLastFactsSummary> {
        await self.withTransaction(transactionClass: .maintenance) {
            let preflight = self.withSynchronousActorWork(.diagnosticsHistorySummaryRead) {
                (
                    self.diagnosticsUnavailableAfterWriteFailure,
                    WatchRelayDiagnosticsFiles.summaryURL(rootURL: self.paths.rootURL)
                )
            }
            guard !preflight.0 else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            let url = preflight.1
            guard await self.fileWriter.fileExists(at: url) else {
                return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            }
            do {
                return .available(try await self.decodeDiagnosticsSummary(
                    from: url,
                    boundary: .diagnosticsHistorySummaryRead
                ).lastFactsSummary)
            } catch {
                await self.resetCorruptDiagnosticFile(
                    at: url,
                    error: error,
                    boundary: .diagnosticsHistorySummaryRead
                )
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
        await self.withTransaction(transactionClass: .maintenance) {
            let succeeded = await self.performDiagnosticsWrite(
                "enqueue",
                segmentID: manifest.id,
                boundary: .relayDiagnosticsPersistence
            ) {
                let sourcePresent = await self.fileWriter.fileExists(at: bundleURL)
                let sourceBytes = await self.diagnosticsSourceByteSize(
                    at: bundleURL,
                    sourcePresent: sourcePresent,
                    boundary: .relayDiagnosticsPersistence
                )
                var sidecar = await self.diagnosticsSidecarForUpdate(
                    manifest: manifest,
                    directoryURL: directoryURL,
                    boundary: .relayDiagnosticsPersistence
                )
                if sidecar.originalEnqueuedAt == nil {
                    sidecar.originalEnqueuedAt = date
                }
                sidecar.latestEnqueuedAt = date
                sidecar.attemptCount = try Self.incrementDiagnosticsCounter(sidecar.attemptCount)
                sidecar.sourceBytes = sourceBytes
                sidecar.sourcePresent = sourcePresent
                let fact = WatchRelayFactCounter(at: date, count: sidecar.attemptCount, segmentID: manifest.id)
                sidecar.lastFacts.lastEnqueue = fact
                try await self.writeDiagnosticsSidecar(
                    sidecar,
                    directoryURL: directoryURL,
                    boundary: .relayDiagnosticsPersistence
                )

                var summary = await self.diagnosticsSummaryForUpdate(boundary: .relayDiagnosticsPersistence)
                summary.lastEnqueue = fact
                try await self.writeDiagnosticsSummary(summary, boundary: .relayDiagnosticsPersistence)
            }
            if succeeded {
                self.bumpRelevantMutationGeneration()
            }
            return succeeded
        }
    }

    func recordRelayTransferCompletion(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        succeeded: Bool,
        failure: WatchConnectivityTransferFailureSnapshot?,
        at date: Date
    ) async {
        _ = await self.withTransaction(transactionClass: .maintenance) {
            await self.performDiagnosticsWrite(
                "transfer completion",
                segmentID: manifest.id,
                boundary: .relayDiagnosticsPersistence
            ) {
                var summary = await self.diagnosticsSummaryForUpdate(boundary: .relayDiagnosticsPersistence)
                let previousSuccess = summary.lastTransferCompletion?.successCount ?? 0
                let previousFailure = summary.lastTransferCompletion?.failureCount ?? 0
                let completion = WatchRelayTransferCompletionFact(
                    at: date,
                    segmentID: manifest.id,
                    succeeded: succeeded,
                    successCount: succeeded ? try Self.incrementDiagnosticsCounter(previousSuccess) : previousSuccess,
                    failureCount: succeeded ? previousFailure : try Self.incrementDiagnosticsCounter(previousFailure)
                )
                var sidecar = await self.diagnosticsSidecarForUpdate(
                    manifest: manifest,
                    directoryURL: directoryURL,
                    boundary: .relayDiagnosticsPersistence
                )
                sidecar.lastFacts.lastTransferCompletion = completion
                summary.lastTransferCompletion = completion
                if let failure {
                    let structured = WatchTransferStructuredFailure(time: date, snapshot: failure)
                    sidecar.lastFacts.lastStructuredFailure = structured
                    summary.lastStructuredFailure = structured
                }
                try await self.writeDiagnosticsSidecar(
                    sidecar,
                    directoryURL: directoryURL,
                    boundary: .relayDiagnosticsPersistence
                )
                try await self.writeDiagnosticsSummary(summary, boundary: .relayDiagnosticsPersistence)
            }
        }
    }

    func recordRelayDurableACK(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        at date: Date
    ) async {
        _ = await self.withTransaction(transactionClass: .maintenance) {
            await self.performDiagnosticsWrite(
                "durable ack",
                segmentID: manifest.id,
                boundary: .relayDiagnosticsPersistence
            ) {
                var summary = await self.diagnosticsSummaryForUpdate(boundary: .relayDiagnosticsPersistence)
                let count = try Self.incrementDiagnosticsCounter(summary.lastDurableACK?.count ?? 0)
                let fact = WatchRelayFactCounter(at: date, count: count, segmentID: manifest.id)
                var sidecar = await self.diagnosticsSidecarForUpdate(
                    manifest: manifest,
                    directoryURL: directoryURL,
                    boundary: .relayDiagnosticsPersistence
                )
                sidecar.lastFacts.lastDurableACK = fact
                try await self.writeDiagnosticsSidecar(
                    sidecar,
                    directoryURL: directoryURL,
                    boundary: .relayDiagnosticsPersistence
                )
                summary.lastDurableACK = fact
                try await self.writeDiagnosticsSummary(summary, boundary: .relayDiagnosticsPersistence)
            }
        }
    }

    func recordRelayQueueReconciliation(
        counts: WatchRelayReconciliationCounts,
        observedFileTransferCount: Int,
        activeManifestCount: Int,
        at date: Date
    ) async -> Bool {
        await self.withTransaction(transactionClass: .maintenance) {
            await self.performDiagnosticsWrite(
                "queue reconciliation",
                segmentID: nil,
                boundary: .relayDiagnosticsPersistence
            ) {
                let fact = self.withSynchronousActorWork(.relayDiagnosticsPersistence) {
                    WatchRelayQueueReconciliationFact(
                        at: date,
                        counts: counts,
                        observedFileTransferCount: observedFileTransferCount,
                        activeManifestCount: activeManifestCount
                    )
                }
                var summary = await self.diagnosticsSummaryForUpdate(boundary: .relayDiagnosticsPersistence)
                summary.lastQueueReconciliationObservation = fact
                try await self.writeDiagnosticsSummary(summary, boundary: .relayDiagnosticsPersistence)
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
        _ = await self.withTransaction(transactionClass: .maintenance) {
            await self.performDiagnosticsWrite(
                "background wake",
                segmentID: nil,
                boundary: .relayDiagnosticsPersistence
            ) {
                let fact = self.withSynchronousActorWork(.relayDiagnosticsPersistence) {
                    WatchRelayBackgroundWakeFact(
                        at: date,
                        reason: reason,
                        heldTaskCount: heldTaskCount,
                        completedTaskCount: completedTaskCount,
                        deadlineCount: deadlineCount
                    )
                }
                var summary = await self.diagnosticsSummaryForUpdate(boundary: .relayDiagnosticsPersistence)
                if reason == "deadline" {
                    summary.lastBackgroundWakeDeadline = fact
                } else {
                    summary.lastBackgroundWakeCompletion = fact
                }
                try await self.writeDiagnosticsSummary(summary, boundary: .relayDiagnosticsPersistence)
            }
        }
    }

    func readSessionRecord(
        transactionClass: WatchCaptureStorageTransactionClass
    ) async throws -> WatchCaptureSessionRecord? {
        try await self.withTransaction(transactionClass: transactionClass) {
            let url = self.withSynchronousActorWork(.sessionRecord) {
                self.paths.sessionRecordURL()
            }
            guard await self.fileWriter.fileExists(at: url) else { return nil }
            let data = try await self.fileWriter.readData(from: url)
            return try self.withSynchronousActorWork(.sessionRecord) {
                try self.manifestDecoder.decode(WatchCaptureSessionRecord.self, from: data)
            }
        }
    }

    func writeSessionRecord(
        _ record: WatchCaptureSessionRecord,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async throws {
        try await self.withTransaction(transactionClass: transactionClass) {
            let write = try self.withSynchronousActorWork(.sessionRecord) {
                (self.paths.sessionRecordURL(), try self.manifestEncoder.encode(record))
            }
            try await self.fileWriter.atomicReplaceFile(
                at: write.0,
                with: write.1
            )
        }
    }

    func readSessionHistory(asOf: Date) async -> WatchCaptureSessionHistoryReadResult {
        await self.withTransaction(transactionClass: .maintenance) {
            await self.readSessionHistoryInner(asOf: asOf, boundary: .sessionHistory)
        }
    }

    func sessionHistoryEntry(
        sessionID: String,
        asOf: Date,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async -> WatchCaptureSessionHistoryEntry? {
        await self.withTransaction(transactionClass: transactionClass) {
            guard case let .available(entries) = await self.readSessionHistoryInner(
                asOf: asOf,
                boundary: .sessionHistory
            ) else {
                return nil
            }
            return self.withSynchronousActorWork(.sessionHistory) {
                entries.first { $0.sessionID == sessionID }
            }
        }
    }

    func upsertSessionHistory(
        _ entry: WatchCaptureSessionHistoryEntry,
        asOf: Date,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async throws {
        try await self.withTransaction(transactionClass: transactionClass) {
            try await self.upsertSessionHistoryInner(entry, asOf: asOf, boundary: .sessionHistory)
        }
    }

    func resolveAndPersistTerminalTuple(
        recordProposal: WatchCaptureSessionRecord?,
        proposedTerminal: WatchCaptureTerminalTuple,
        asOf: Date
    ) async -> WatchCaptureTerminalTupleResolution {
        await self.withTransaction(transactionClass: .captureSafety) {
            await self.resolveAndPersistTerminalTupleInner(
                recordProposal: recordProposal,
                proposedTerminal: proposedTerminal,
                asOf: asOf
            )
        }
    }

    func mergeTerminalNoticeMetadata(
        expected: WatchCaptureTerminalTuple,
        update: WatchCaptureTerminalNoticeMetadata
    ) async -> Bool {
        await self.withTransaction(transactionClass: .maintenance) {
            await self.mergeTerminalNoticeMetadataInner(expected: expected, update: update)
        }
    }

    func readSessionHistoryCounter() async -> WatchCaptureSessionHistoryCounter? {
        await self.withTransaction(transactionClass: .maintenance) {
            await self.readSessionHistoryCounterInner(boundary: .sessionHistory)
        }
    }

    func incrementLifetimeSessionCounter() async throws -> WatchCaptureSessionHistoryCounter? {
        try await self.withTransaction(transactionClass: .captureSafety) {
            let url = self.withSynchronousActorWork(.sessionHistory) {
                self.paths.sessionHistoryCounterURL()
            }
            if await self.fileWriter.fileExists(at: url) {
                guard let data = try? await self.fileWriter.readData(from: url) else {
                    return nil
                }
                let updated: WatchCaptureSessionHistoryCounter? = self.withSynchronousActorWork(.sessionHistory) {
                    guard let current = try? self.sessionDecoder.decode(WatchCaptureSessionHistoryCounter.self, from: data) else {
                        return nil
                    }
                    return WatchCaptureSessionHistoryCounter(
                        epoch: current.epoch,
                        lifetimeSessionsStarted: current.lifetimeSessionsStarted + 1
                    )
                }
                guard let updated else { return nil }
                let encoded = try self.withSynchronousActorWork(.sessionHistory) {
                    try self.sessionEncoder.encode(updated)
                }
                try await self.fileWriter.atomicReplaceFile(at: url, with: encoded)
                return updated
            }
            let counter = self.withSynchronousActorWork(.sessionHistory) {
                WatchCaptureSessionHistoryCounter(epoch: UUID().uuidString, lifetimeSessionsStarted: 1)
            }
            let encoded = try self.withSynchronousActorWork(.sessionHistory) {
                try self.sessionEncoder.encode(counter)
            }
            try await self.fileWriter.atomicReplaceFile(at: url, with: encoded)
            return counter
        }
    }

    func revertLifetimeSessionCounterIncrement(
        _ incremented: WatchCaptureSessionHistoryCounter
    ) async throws {
        try await self.withTransaction(transactionClass: .captureSafety) {
            guard let current = await self.readSessionHistoryCounterInner(boundary: .sessionHistory),
                  current.epoch == incremented.epoch,
                  current.lifetimeSessionsStarted == incremented.lifetimeSessionsStarted,
                  current.lifetimeSessionsStarted > 0
            else { return }
            let reverted = self.withSynchronousActorWork(.sessionHistory) {
                WatchCaptureSessionHistoryCounter(
                    epoch: current.epoch,
                    lifetimeSessionsStarted: current.lifetimeSessionsStarted - 1
                )
            }
            let data = try self.withSynchronousActorWork(.sessionHistory) {
                try self.sessionEncoder.encode(reverted)
            }
            try await self.fileWriter.atomicReplaceFile(
                at: self.paths.sessionHistoryCounterURL(),
                with: data
            )
        }
    }

    func openLocationLogHeader(at url: URL) async throws {
        try await self.withTransaction(transactionClass: .captureSafety) {
            let data = try self.withSynchronousActorWork(.capturePreparation) {
                try self.locationSegmentData(fixCount: 0, gap: true, fixLines: [])
            }
            try await self.fileWriter.writeData(data, to: url, options: .atomic)
        }
    }

    func appendLocationFix(_ fix: WatchLocationFix, at url: URL) async throws {
        try await self.withTransaction(transactionClass: .captureSafety) {
            let data = try self.withSynchronousActorWork(.locationLogAppend) {
                try self.locationEncoder.encode(LocationFixLine(fix: fix))
            }
            try await self.fileWriter.appendLine(
                data,
                to: url
            )
        }
    }

    func finalizeLocationLog(
        at url: URL,
        armed: Bool
    ) async throws -> WatchCaptureLocationLogFinalizedStats {
        try await self.withTransaction(transactionClass: .captureSafety) {
            let fixLines = try await self.durableLocationFixLines(at: url, boundary: .locationLogReconciliation)
            let output = try self.withSynchronousActorWork(.locationLogReconciliation) { () -> (WatchCaptureLocationLogFinalizedStats, Data) in
                let stats = WatchCaptureLocationLogFinalizedStats(
                    fixCount: fixLines.count,
                    gap: armed && fixLines.isEmpty
                )
                return (
                    stats,
                    try self.locationSegmentData(
                        fixCount: stats.fixCount,
                        gap: stats.gap,
                        fixLines: fixLines
                    )
                )
            }
            try await self.fileWriter.atomicReplaceFile(
                at: url,
                with: output.1
            )
            return output.0
        }
    }

    private struct CatalogRootInspection: Sendable {
        let terminalCatalog: WatchCaptureCatalog?
        let days: [URL]
    }

    private struct CatalogDayInspection: Sendable {
        let segments: [URL]
        let issues: [WatchCaptureCatalogIssue]
    }

    private struct CatalogSegmentInspection: Sendable {
        let entry: WatchCaptureCatalogEntry?
        let issues: [WatchCaptureCatalogIssue]
    }

    private func scanCatalogStep<Value: Sendable>(
        transactionClass: WatchCaptureStorageTransactionClass,
        _ body: () async -> Value
    ) async -> (value: Value, wasInterrupted: Bool) {
        let admissionCountBefore = self.transactionAdmissionCount
        let value = await self.withTransaction(transactionClass: transactionClass, body)
        return (
            value,
            self.transactionAdmissionCount > admissionCountBefore + 1
        )
    }

    private func scanCatalogInner(
        transactionClass: WatchCaptureStorageTransactionClass,
        boundary: WatchSignpostBoundary
    ) async -> WatchCaptureCatalog {
        let generation = self.relevantMutationGeneration
        let rootStep = await self.scanCatalogStep(transactionClass: transactionClass) {
            await self.scanCatalogRootStep(boundary: boundary)
        }
        let root = rootStep.value
        if let terminalCatalog = root.terminalCatalog {
            return terminalCatalog.withRelevantMutationGeneration(generation)
        }

        var entries: [WatchCaptureCatalogEntry] = []
        var issues: [WatchCaptureCatalogIssue] = []
        var wasInterrupted = rootStep.wasInterrupted
        catalogLoop: for dayURL in root.days.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if case .maintenance = transactionClass, Task.isCancelled {
                wasInterrupted = true
                break
            }
            let day = dayURL.lastPathComponent
            guard day != ".relay-bundles",
                  day != WatchCaptureStoragePaths.sessionRecordFileName,
                  day != Self.historyFileName,
                  day != Self.counterFileName,
                  day != ".relay-diagnostics-summary.json" else { continue }

            let dayStep = await self.scanCatalogStep(transactionClass: transactionClass) {
                await self.scanCatalogDayStep(at: dayURL, day: day, boundary: boundary)
            }
            let dayInspection = dayStep.value
            wasInterrupted = wasInterrupted || dayStep.wasInterrupted
            issues.append(contentsOf: dayInspection.issues)
            for segmentURL in dayInspection.segments.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if case .maintenance = transactionClass, Task.isCancelled {
                    wasInterrupted = true
                    break catalogLoop
                }
                let segmentStep = await self.scanCatalogStep(transactionClass: transactionClass) {
                    await self.scanCatalogSegmentStep(
                        at: segmentURL,
                        day: day,
                        boundary: boundary
                    )
                }
                let inspection = segmentStep.value
                wasInterrupted = wasInterrupted || segmentStep.wasInterrupted
                if let entry = inspection.entry {
                    entries.append(entry)
                }
                issues.append(contentsOf: inspection.issues)
            }
        }

        return self.withSynchronousActorWork(boundary) {
            if wasInterrupted {
                issues.append(self.issue(.incompleteSubtree, namespace: "catalog"))
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
            return WatchCaptureCatalog(
                rootState: rootState,
                entries: entries,
                issues: issues.sorted { $0.id < $1.id },
                relevantMutationGeneration: generation
            )
        }
    }

    private func scanCatalogRootStep(boundary: WatchSignpostBoundary) async -> CatalogRootInspection {
        let rootURL = self.withSynchronousActorWork(boundary) { self.paths.rootURL }
        let rootKind: WatchCaptureStorageItemKind
        do { rootKind = try await self.fileWriter.itemKind(at: rootURL) }
        catch {
            return CatalogRootInspection(
                terminalCatalog: WatchCaptureCatalog(rootState: .unavailable(.unreadable), entries: [], issues: [], relevantMutationGeneration: 0),
                days: []
            )
        }
        guard rootKind != .missing else {
            return CatalogRootInspection(
                terminalCatalog: WatchCaptureCatalog(rootState: .unavailable(.missing), entries: [], issues: [], relevantMutationGeneration: 0),
                days: []
            )
        }
        guard rootKind == .directory else {
            return CatalogRootInspection(
                terminalCatalog: WatchCaptureCatalog(rootState: .unavailable(.notDirectory), entries: [], issues: [], relevantMutationGeneration: 0),
                days: []
            )
        }
        guard let days = try? await self.fileWriter.contentsOfDirectory(at: rootURL) else {
            return CatalogRootInspection(
                terminalCatalog: WatchCaptureCatalog(rootState: .unavailable(.notEnumerable), entries: [], issues: [], relevantMutationGeneration: 0),
                days: []
            )
        }
        return CatalogRootInspection(terminalCatalog: nil, days: days)
    }

    private func scanCatalogDayStep(
        at dayURL: URL,
        day: String,
        boundary: WatchSignpostBoundary
    ) async -> CatalogDayInspection {
        let dayKind: WatchCaptureStorageItemKind
        do {
            dayKind = try await self.fileWriter.itemKind(at: dayURL)
        } catch {
            return CatalogDayInspection(
                segments: [],
                issues: [
                    self.issue(.fileTypeLookupFailure, namespace: day),
                    self.issue(.incompleteSubtree, namespace: day),
                ]
            )
        }
        guard dayKind == .directory else {
            return CatalogDayInspection(
                segments: [],
                issues: [self.issue(.unexpectedShape, namespace: day)]
            )
        }
        guard let segments = try? await self.fileWriter.contentsOfDirectory(at: dayURL) else {
            return CatalogDayInspection(
                segments: [],
                issues: [self.issue(.incompleteSubtree, namespace: day)]
            )
        }
        return CatalogDayInspection(segments: segments, issues: [])
    }

    private func scanCatalogSegmentStep(
        at segmentURL: URL,
        day: String,
        boundary: WatchSignpostBoundary
    ) async -> CatalogSegmentInspection {
        let segment = segmentURL.lastPathComponent
        let id = WatchCaptureCatalogEntryID(day: day, segment: segment)
        let namespace = "\(day)/\(segment)"
        let segmentKind: WatchCaptureStorageItemKind
        do {
            segmentKind = try await self.fileWriter.itemKind(at: segmentURL)
        } catch {
            return CatalogSegmentInspection(
                entry: nil,
                issues: [self.issue(.fileTypeLookupFailure, namespace: namespace)]
            )
        }
        guard segmentKind == .directory else {
            return CatalogSegmentInspection(
                entry: nil,
                issues: [self.issue(.unexpectedShape, namespace: namespace)]
            )
        }
        let manifestURL = self.paths.manifestURL(directory: segmentURL)
        guard await self.fileWriter.fileExists(at: manifestURL) else {
            return CatalogSegmentInspection(
                entry: nil,
                issues: [self.issue(.missingManifest, namespace: namespace)]
            )
        }
        do {
            let data = try await self.fileWriter.readData(from: manifestURL)
            let manifest = try self.manifestDecoder.decode(WatchSegmentManifest.self, from: data)
            guard manifest.day == day, manifest.segment == segment else {
                return CatalogSegmentInspection(
                    entry: nil,
                    issues: [self.issue(.pathMismatch, namespace: namespace)]
                )
            }
            let mediaURLs = self.withSynchronousActorWork(boundary) {
                [
                    self.paths.audioURL(directory: segmentURL),
                    self.paths.locationURL(directory: segmentURL),
                ]
            }
            var issues: [WatchCaptureCatalogIssue] = []
            for mediaURL in mediaURLs {
                do {
                    switch try await self.fileWriter.itemKind(at: mediaURL) {
                    case .directory:
                        issues.append(self.issue(
                            .unexpectedShape,
                            namespace: "\(namespace)/\(mediaURL.lastPathComponent)"
                        ))
                    case .missing, .file:
                        break
                    }
                } catch {
                    issues.append(self.issue(
                        .fileTypeLookupFailure,
                        namespace: "\(namespace)/\(mediaURL.lastPathComponent)"
                    ))
                }
            }
            guard issues.isEmpty else {
                return CatalogSegmentInspection(entry: nil, issues: issues)
            }
            let witness = await self.contentWitness(
                manifestData: data,
                directoryURL: segmentURL,
                boundary: boundary
            )
            let entry = self.withSynchronousActorWork(boundary) {
                WatchCaptureCatalogEntry(
                    id: id,
                    directoryURL: segmentURL,
                    manifestURL: manifestURL,
                    manifest: manifest,
                    witness: witness
                )
            }
            return CatalogSegmentInspection(entry: entry, issues: [])
        } catch {
            return CatalogSegmentInspection(
                entry: nil,
                issues: [self.issue(.manifestDecodeFailure, namespace: namespace)]
            )
        }
    }

    private func currentRelayEntry(
        _ expected: WatchCaptureCatalogEntry,
        boundary: WatchSignpostBoundary
    ) async throws -> WatchCaptureCatalogEntry {
        let manifestURL = self.withSynchronousActorWork(boundary) { expected.manifestURL }
        guard await self.fileWriter.fileExists(at: manifestURL),
              let manifestData = try? await self.fileWriter.readData(from: manifestURL)
        else {
            throw WatchCaptureStorageConflict.contentWitnessChanged(id: expected.id)
        }
        let manifest = try self.withSynchronousActorWork(boundary) {
            guard let manifest = try? self.manifestDecoder.decode(WatchSegmentManifest.self, from: manifestData),
                  manifest.id == expected.manifest.id,
                  manifest.day == expected.id.day,
                  manifest.segment == expected.id.segment
            else {
                throw WatchCaptureStorageConflict.contentWitnessChanged(id: expected.id)
            }
            return manifest
        }
        let witness = await self.contentWitness(
            manifestData: manifestData,
            directoryURL: expected.directoryURL,
            boundary: boundary
        )
        return self.withSynchronousActorWork(boundary) {
            WatchCaptureCatalogEntry(
                id: expected.id,
                directoryURL: expected.directoryURL,
                manifestURL: manifestURL,
                manifest: manifest,
                witness: witness
            )
        }
    }

    private func verifiedRelayEntry(
        _ expected: WatchCaptureCatalogEntry,
        boundary: WatchSignpostBoundary
    ) async throws -> WatchCaptureCatalogEntry {
        let current = try await self.currentRelayEntry(expected, boundary: boundary)
        try self.withSynchronousActorWork(boundary) {
            try self.verifyRelayWitness(current, against: expected)
        }
        return current
    }

    private func verifyRelayWitness(
        _ current: WatchCaptureCatalogEntry,
        against expected: WatchCaptureCatalogEntry
    ) throws {
        guard current.witness.hasCompleteMediaEvidence,
              expected.witness.hasCompleteMediaEvidence,
              current.witness == expected.witness
        else {
            throw WatchCaptureStorageConflict.contentWitnessChanged(id: expected.id)
        }
    }

    private func writeRelayManifest(
        _ manifest: WatchSegmentManifest,
        replacing entry: WatchCaptureCatalogEntry,
        boundary: WatchSignpostBoundary
    ) async throws -> WatchCaptureCatalogEntry {
        let data = try self.withSynchronousActorWork(boundary) {
            try self.manifestEncoder.encode(manifest)
        }
        try await self.fileWriter.writeData(data, to: entry.manifestURL, options: .atomic)
        self.bumpRelevantMutationGeneration()
        let witness = await self.contentWitness(
            manifestData: data,
            directoryURL: entry.directoryURL,
            boundary: boundary
        )
        return self.withSynchronousActorWork(boundary) {
            WatchCaptureCatalogEntry(
                id: entry.id,
                directoryURL: entry.directoryURL,
                manifestURL: entry.manifestURL,
                manifest: manifest,
                witness: witness
            )
        }
    }

    private func relayBundleData(
        for entry: WatchCaptureCatalogEntry,
        boundary: WatchSignpostBoundary
    ) async throws -> Data {
        var files: [String: Data] = [:]
        let manifestData = try await self.fileWriter.readData(from: entry.manifestURL)
        try self.withSynchronousActorWork(boundary) {
            guard manifestData == entry.witness.manifestData else {
                throw WatchCaptureStorageConflict.contentWitnessChanged(id: entry.id)
            }
            files[WatchSegmentBundleCodec.manifestFilename] = manifestData
        }

        let audioURL = self.withSynchronousActorWork(boundary) {
            self.paths.audioURL(directory: entry.directoryURL)
        }
        if await self.fileWriter.fileExists(at: audioURL) {
            files[WatchSegmentBundleCodec.audioFilename] = try await self.fileWriter.readData(from: audioURL)
        }

        let locationURL = self.withSynchronousActorWork(boundary) {
            self.paths.locationURL(directory: entry.directoryURL)
        }
        if await self.fileWriter.fileExists(at: locationURL) {
            files[WatchSegmentBundleCodec.locationFilename] = try await self.fileWriter.readData(from: locationURL)
        }

        return try self.withSynchronousActorWork(boundary) {
            try PropertyListSerialization.data(
                fromPropertyList: files,
                format: .binary,
                options: 0
            )
        }
    }

    private func contentWitness(
        manifestData: Data,
        directoryURL: URL,
        boundary: WatchSignpostBoundary
    ) async -> WatchCaptureContentWitness {
        let urls = self.withSynchronousActorWork(boundary) {
            (
                self.paths.audioURL(directory: directoryURL),
                self.paths.locationURL(directory: directoryURL)
            )
        }
        let audioBytes = try? await self.fileWriter.fileSize(at: urls.0)
        let locationBytes = try? await self.fileWriter.fileSize(at: urls.1)
        let audioFingerprint = try? await self.fileWriter.fileFingerprint(at: urls.0)
        let locationFingerprint = try? await self.fileWriter.fileFingerprint(at: urls.1)
        return self.withSynchronousActorWork(boundary) {
            WatchCaptureContentWitness(
                manifestData: manifestData,
                audioBytes: audioBytes,
                locationBytes: locationBytes,
                audioFingerprint: audioFingerprint,
                locationFingerprint: locationFingerprint
            )
        }
    }

    private func currentRelayManifest(
        at directoryURL: URL,
        boundary: WatchSignpostBoundary
    ) async -> (id: UUID, entryID: WatchCaptureCatalogEntryID)? {
        let manifestURL = self.withSynchronousActorWork(boundary) {
            self.paths.manifestURL(directory: directoryURL)
        }
        guard await self.fileWriter.fileExists(at: manifestURL),
              let data = try? await self.fileWriter.readData(from: manifestURL)
        else {
            return nil
        }
        return self.withSynchronousActorWork(boundary) {
            guard let manifest = try? self.manifestDecoder.decode(WatchSegmentManifest.self, from: data) else {
                return nil
            }
            return (
                manifest.id,
                WatchCaptureCatalogEntryID(day: manifest.day, segment: manifest.segment)
            )
        }
    }

    private func verifiedRelayDeletionEntry(
        _ expected: WatchCaptureCatalogEntry,
        boundary: WatchSignpostBoundary
    ) async throws -> WatchCaptureCatalogEntry {
        do {
            return try await self.verifiedRelayEntry(expected, boundary: boundary)
        } catch WatchCaptureStorageConflict.contentWitnessChanged {
            let found = await self.currentRelayManifest(at: expected.directoryURL, boundary: boundary)
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
        boundary: WatchSignpostBoundary,
        _ body: () async throws -> Void
    ) async -> Bool {
        do {
            try await body()
            return true
        } catch {
            self.diagnosticsUnavailableAfterWriteFailure = true
            let id = self.withSynchronousActorWork(boundary) {
                segmentID?.uuidString ?? "none"
            }
            watchRelayDiagnosticsLog.error(
                "watch relay diagnostic \(label, privacy: .public) write failed id=\(id, privacy: .public): \(String(describing: error), privacy: .private)"
            )
            return false
        }
    }

    private func diagnosticsSidecarForUpdate(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        boundary: WatchSignpostBoundary
    ) async -> WatchRelaySegmentDiagnosticsSidecar {
        let url = self.withSynchronousActorWork(boundary) {
            WatchRelayDiagnosticsFiles.sidecarURL(directoryURL: directoryURL)
        }
        guard await self.fileWriter.fileExists(at: url) else {
            return self.withSynchronousActorWork(boundary) {
                WatchRelaySegmentDiagnosticsSidecar(segmentID: manifest.id)
            }
        }
        do {
            return try await self.decodeDiagnosticsSidecar(
                from: url,
                expectedID: manifest.id,
                boundary: boundary
            )
        } catch {
            await self.resetCorruptDiagnosticFile(at: url, error: error, boundary: boundary)
            return self.withSynchronousActorWork(boundary) {
                WatchRelaySegmentDiagnosticsSidecar(segmentID: manifest.id)
            }
        }
    }

    private func diagnosticsSummaryForUpdate(
        boundary: WatchSignpostBoundary
    ) async -> WatchRelayDiagnosticsSummaryFile {
        let url = self.withSynchronousActorWork(boundary) {
            WatchRelayDiagnosticsFiles.summaryURL(rootURL: self.paths.rootURL)
        }
        guard await self.fileWriter.fileExists(at: url) else { return .empty }
        do {
            return try await self.decodeDiagnosticsSummary(from: url, boundary: boundary)
        } catch {
            await self.resetCorruptDiagnosticFile(at: url, error: error, boundary: boundary)
            return .empty
        }
    }

    private func diagnosticsSourceByteSize(
        at url: URL,
        sourcePresent: Bool,
        boundary: WatchSignpostBoundary
    ) async -> Int64? {
        guard sourcePresent else { return nil }
        let sourceURL = self.withSynchronousActorWork(boundary) { url }
        return try? await self.fileWriter.fileSize(at: sourceURL)
    }

    private func decodeDiagnosticsSidecar(
        from url: URL,
        expectedID: UUID,
        boundary: WatchSignpostBoundary
    ) async throws -> WatchRelaySegmentDiagnosticsSidecar {
        let data = try await self.fileWriter.readData(from: url)
        return try self.withSynchronousActorWork(boundary) {
            let sidecar = try self.diagnosticsDecoder.decode(
                WatchRelaySegmentDiagnosticsSidecar.self,
                from: data
            )
            guard sidecar.version <= WatchRelaySegmentDiagnosticsSidecar.currentVersion,
                  sidecar.segmentID == expectedID
            else {
                throw WatchRelayDiagnosticsStoreError.unsupportedOrMismatchedSidecar
            }
            try Self.validateDiagnosticsSidecarInvariants(sidecar)
            return sidecar
        }
    }

    private func decodeDiagnosticsSummary(
        from url: URL,
        boundary: WatchSignpostBoundary
    ) async throws -> WatchRelayDiagnosticsSummaryFile {
        let data = try await self.fileWriter.readData(from: url)
        return try self.withSynchronousActorWork(boundary) {
            let summary = try self.diagnosticsDecoder.decode(WatchRelayDiagnosticsSummaryFile.self, from: data)
            guard summary.version <= WatchRelayDiagnosticsSummaryFile.currentVersion else {
                throw WatchRelayDiagnosticsStoreError.unsupportedSummary
            }
            try Self.validateDiagnosticsSummaryInvariants(summary)
            return summary
        }
    }

    private func writeDiagnosticsSidecar(
        _ sidecar: WatchRelaySegmentDiagnosticsSidecar,
        directoryURL: URL,
        boundary: WatchSignpostBoundary
    ) async throws {
        let data = try self.withSynchronousActorWork(boundary) {
            try self.diagnosticsEncoder.encode(sidecar)
        }
        try await self.fileWriter.writeData(
            data,
            to: WatchRelayDiagnosticsFiles.sidecarURL(directoryURL: directoryURL),
            options: .atomic
        )
    }

    private func writeDiagnosticsSummary(
        _ summary: WatchRelayDiagnosticsSummaryFile,
        boundary: WatchSignpostBoundary
    ) async throws {
        let data = try self.withSynchronousActorWork(boundary) {
            try self.diagnosticsEncoder.encode(summary)
        }
        try await self.fileWriter.writeData(
            data,
            to: WatchRelayDiagnosticsFiles.summaryURL(rootURL: self.paths.rootURL),
            options: .atomic
        )
    }

    private func resetCorruptDiagnosticFile(
        at url: URL,
        error: any Error,
        boundary: WatchSignpostBoundary
    ) async {
        self.withSynchronousActorWork(boundary) {
            let key = url.standardizedFileURL.path
            if self.loggedCorruptDiagnosticURLs.insert(key).inserted {
                watchRelayDiagnosticsLog.error(
                    "watch relay diagnostic file reset path=\(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .private)"
                )
            }
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
        .staleRelayState(id: entry.manifest.id, expected: expected, actual: actual)
    }

    private struct RawSessionRecord: Sendable {
        let record: WatchCaptureSessionRecord?
        let isReadable: Bool
    }

    private struct RawSessionHistoryPopulation: Sendable {
        let entries: [WatchCaptureSessionHistoryEntry]
        let unreadableLines: [Data]
        let hadDamage: Bool
        let fileExists: Bool
        let isReadable: Bool
    }

    private func resolveAndPersistTerminalTupleInner(
        recordProposal: WatchCaptureSessionRecord?,
        proposedTerminal: WatchCaptureTerminalTuple,
        asOf: Date
    ) async -> WatchCaptureTerminalTupleResolution {
        let currentRecord = await self.readRawSessionRecord(boundary: .sessionRecord)
        let rawHistory = await self.readRawSessionHistoryPopulation(boundary: .sessionHistory)
        guard currentRecord.isReadable else { return .failClosed }

        var durableCandidates: [WatchCaptureTerminalTuple] = []
        if let record = currentRecord.record {
            durableCandidates.append(self.terminalTuple(from: record))
        }
        let matchingHistory = rawHistory.entries.filter { $0.sessionID == proposedTerminal.sessionID }
        durableCandidates.append(contentsOf: matchingHistory.map(self.terminalTuple(from:)))

        guard self.allTerminalTupleIdentitiesMatch(
            [proposedTerminal]
                + durableCandidates
                + (recordProposal.map { [self.terminalTuple(from: $0)] } ?? [])
        ) else {
            return .failClosed
        }

        var reason: WatchCaptureTerminalReason?
        var disposition: WatchCaptureTerminalDisposition?
        var durableTerminalAt: Date?
        for candidate in durableCandidates {
            guard self.mergeTerminalValue(candidate.reason, into: &reason),
                  self.mergeTerminalValue(candidate.disposition, into: &disposition),
                  self.mergeTerminalValue(candidate.terminalAt, into: &durableTerminalAt)
            else {
                return .failClosed
            }
        }
        if let recordProposal {
            let proposal = self.terminalTuple(from: recordProposal)
            guard self.mergeTerminalValue(proposal.reason, into: &reason),
                  self.mergeTerminalValue(proposal.disposition, into: &disposition)
            else {
                return .failClosed
            }
        }
        guard self.mergeTerminalValue(proposedTerminal.reason, into: &reason),
              self.mergeTerminalValue(proposedTerminal.disposition, into: &disposition)
        else {
            return .failClosed
        }

        if reason == .ownerStopped, disposition == nil {
            disposition = .ownerStopped
        } else if disposition == .ownerStopped, reason == nil {
            reason = .ownerStopped
        }
        guard let reason, let disposition else { return .failClosed }
        let terminalAt = durableTerminalAt ?? proposedTerminal.terminalAt ?? asOf

        let durableNoticeOwed = currentRecord.record?.state == .terminal
            ? currentRecord.record?.noticeOwed
            : matchingHistory.first?.noticeOwed
        let resolved = WatchCaptureTerminalTuple(
            sessionID: proposedTerminal.sessionID,
            startedAt: proposedTerminal.startedAt,
            reason: reason,
            disposition: disposition,
            terminalAt: terminalAt,
            noticeOwed: durableNoticeOwed ?? proposedTerminal.noticeOwed
        )
        let record = WatchCaptureSessionRecord(
            sessionID: resolved.sessionID,
            startedAt: resolved.startedAt,
            state: .terminal,
            terminalReason: reason,
            terminalDisposition: disposition,
            terminalAt: terminalAt,
            noticeOwed: resolved.noticeOwed,
            segmentsProduced: currentRecord.record?.segmentsProduced ?? recordProposal?.segmentsProduced ?? 0
        )
        let historyEntry = self.resolvedHistoryEntry(
            from: matchingHistory.first,
            tuple: resolved
        )

        guard rawHistory.isReadable || self.isTerminalTupleExpired(resolved, asOf: asOf) else {
            return .failClosed
        }

        let retainedHistory = self.retainedHistoryAfterResolvingTerminalTuple(
            historyEntry,
            from: rawHistory,
            asOf: asOf
        )
        do {
            if rawHistory.isReadable,
               retainedHistory != rawHistory.entries.sorted(by: { $0.startedAt < $1.startedAt }) || !rawHistory.fileExists {
                try await self.writeSessionHistory(
                    entries: retainedHistory,
                    unreadableLines: rawHistory.unreadableLines,
                    boundary: .sessionHistory
                )
            }
            let data = try self.withSynchronousActorWork(.sessionRecord) {
                try self.manifestEncoder.encode(record)
            }
            try await self.fileWriter.atomicReplaceFile(at: self.paths.sessionRecordURL(), with: data)
            return .resolvedAndPersisted(resolved)
        } catch {
            return .failClosed
        }
    }

    private func mergeTerminalNoticeMetadataInner(
        expected: WatchCaptureTerminalTuple,
        update: WatchCaptureTerminalNoticeMetadata
    ) async -> Bool {
        let currentRecord = await self.readRawSessionRecord(boundary: .sessionRecord)
        let rawHistory = await self.readRawSessionHistoryPopulation(boundary: .sessionHistory)
        guard currentRecord.isReadable,
              rawHistory.isReadable,
              !rawHistory.hadDamage
        else {
            return false
        }
        let matchingHistory = rawHistory.entries.filter { $0.sessionID == expected.sessionID }
        guard !matchingHistory.isEmpty,
              matchingHistory.allSatisfy({ self.terminalTuple(from: $0) == expected })
        else {
            return false
        }

        var recordToUpdate: WatchCaptureSessionRecord?
        if var record = currentRecord.record,
           record.sessionID == expected.sessionID {
            guard self.terminalTuple(from: record) == expected else { return false }
            if let noticeOwed = update.noticeOwed {
                record.noticeOwed = noticeOwed
            }
            recordToUpdate = record
        }

        let updatedHistory = rawHistory.entries.map { entry -> WatchCaptureSessionHistoryEntry in
            guard entry.sessionID == expected.sessionID else { return entry }
            var entry = entry
            if let noticeOwed = update.noticeOwed {
                entry.noticeOwed = noticeOwed
            }
            if let noticeDecision = update.noticeDecision {
                entry.noticeDecision = noticeDecision
            }
            if let noticeDelivered = update.noticeDelivered {
                entry.noticeDelivered = noticeDelivered
            }
            if let authorization = update.notificationAuthorizationStatus {
                entry.notificationAuthorizationStatus = authorization
            }
            if let alertSetting = update.notificationAlertSetting {
                entry.notificationAlertSetting = alertSetting
            }
            if let assurance = update.wristAlertAssurance {
                entry.wristAlertAssurance = assurance
            }
            if let settingsRoute = update.settingsRoute {
                entry.settingsRoute = settingsRoute
            }
            return entry
        }
        do {
            try await self.writeSessionHistory(
                entries: updatedHistory.sorted { $0.startedAt < $1.startedAt },
                unreadableLines: rawHistory.unreadableLines,
                boundary: .sessionHistory
            )
            if let recordToUpdate {
                let data = try self.withSynchronousActorWork(.sessionRecord) {
                    try self.manifestEncoder.encode(recordToUpdate)
                }
                try await self.fileWriter.atomicReplaceFile(at: self.paths.sessionRecordURL(), with: data)
            }
            return true
        } catch {
            return false
        }
    }

    private func terminalTuple(from record: WatchCaptureSessionRecord) -> WatchCaptureTerminalTuple {
        WatchCaptureTerminalTuple(
            sessionID: record.sessionID,
            startedAt: record.startedAt,
            reason: record.terminalReason,
            disposition: record.terminalDisposition,
            terminalAt: record.terminalAt,
            noticeOwed: record.noticeOwed
        )
    }

    private func terminalTuple(from entry: WatchCaptureSessionHistoryEntry) -> WatchCaptureTerminalTuple {
        WatchCaptureTerminalTuple(
            sessionID: entry.sessionID,
            startedAt: entry.startedAt,
            reason: entry.terminalReason,
            disposition: entry.terminalDisposition,
            terminalAt: entry.terminalAt,
            noticeOwed: entry.noticeOwed
        )
    }

    private func allTerminalTupleIdentitiesMatch(_ tuples: [WatchCaptureTerminalTuple]) -> Bool {
        guard let first = tuples.first else { return false }
        return tuples.allSatisfy {
            $0.sessionID == first.sessionID && $0.startedAt == first.startedAt
        }
    }

    private func mergeTerminalValue<Value: Equatable>(_ value: Value?, into result: inout Value?) -> Bool {
        guard let value else { return true }
        guard let result else {
            result = value
            return true
        }
        return result == value
    }

    private func resolvedHistoryEntry(
        from existing: WatchCaptureSessionHistoryEntry?,
        tuple: WatchCaptureTerminalTuple
    ) -> WatchCaptureSessionHistoryEntry {
        var entry = existing ?? WatchCaptureSessionHistoryEntry(
            sessionID: tuple.sessionID,
            startedAt: tuple.startedAt,
            terminalAt: nil,
            terminalReason: nil,
            terminalDisposition: nil,
            startRefusalReason: nil,
            settingsRoute: nil,
            noticeOwed: false,
            noticeDecision: nil,
            noticeDelivered: nil,
            notificationAuthorizationStatus: nil,
            notificationAlertSetting: nil,
            wristAlertAssurance: nil,
            audioArmed: false,
            audioSessionIsActive: false,
            locationArmed: false,
            segmentsProduced: 0,
            batteryLevelAtEnd: nil,
            batteryStateAtEnd: nil,
            lowPowerModeEnabledAtEnd: nil,
            thermalStateAtEnd: nil,
            lastVerifiedAudioAt: nil,
            lastAudioCurrentTime: nil,
            zeroAudioCurrentTimeObservationCount: nil,
            locationAdvisory: nil,
            persistenceAdvisory: nil
        )
        entry.terminalAt = tuple.terminalAt
        entry.terminalReason = tuple.reason
        entry.terminalDisposition = tuple.disposition
        entry.noticeOwed = tuple.noticeOwed
        return entry
    }

    private func isTerminalTupleExpired(_ tuple: WatchCaptureTerminalTuple, asOf: Date) -> Bool {
        guard let terminalAt = tuple.terminalAt else { return false }
        return terminalAt < asOf.addingTimeInterval(-Self.sessionHistoryRetention)
    }

    private func retainedHistoryAfterResolvingTerminalTuple(
        _ entry: WatchCaptureSessionHistoryEntry,
        from rawHistory: RawSessionHistoryPopulation,
        asOf: Date
    ) -> [WatchCaptureSessionHistoryEntry] {
        var entriesByID = Dictionary(uniqueKeysWithValues: rawHistory.entries.map { ($0.sessionID, $0) })
        entriesByID[entry.sessionID] = entry
        let cutoff = asOf.addingTimeInterval(-Self.sessionHistoryRetention)
        let ageRetained = entriesByID.values.filter { ($0.terminalAt ?? $0.startedAt) >= cutoff }
        let retained: [WatchCaptureSessionHistoryEntry]
        if rawHistory.isReadable && !rawHistory.hadDamage {
            retained = Array(ageRetained.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maximumSessionHistoryEntryCount))
        } else {
            retained = ageRetained
        }
        return retained.sorted { $0.startedAt < $1.startedAt }
    }

    private func readRawSessionRecord(boundary: WatchSignpostBoundary) async -> RawSessionRecord {
        let url = self.withSynchronousActorWork(boundary) { self.paths.sessionRecordURL() }
        guard await self.fileWriter.fileExists(at: url) else {
            return RawSessionRecord(record: nil, isReadable: true)
        }
        guard let data = try? await self.fileWriter.readData(from: url),
              let record = try? self.withSynchronousActorWork(boundary, {
                  try self.manifestDecoder.decode(WatchCaptureSessionRecord.self, from: data)
              })
        else {
            return RawSessionRecord(record: nil, isReadable: false)
        }
        return RawSessionRecord(record: record, isReadable: true)
    }

    private func readSessionHistoryInner(
        asOf: Date,
        boundary: WatchSignpostBoundary
    ) async -> WatchCaptureSessionHistoryReadResult {
        let parsed = await self.readParsedSessionHistoryEntries(boundary: boundary)
        guard parsed.fileExists else { return .available([]) }
        let update = self.withSynchronousActorWork(boundary) {
            let entries = self.prunedSessionHistoryEntries(parsed.entries, asOf: asOf)
            return (entries, entries.count != parsed.entries.count)
        }
        if update.1 {
            do {
                try await self.writeSessionHistory(
                    entries: update.0,
                    unreadableLines: parsed.unreadableLines,
                    boundary: boundary
                )
            } catch {
                return .unreadable
            }
        }
        return self.withSynchronousActorWork(boundary) {
            guard !parsed.hadDamage || !update.0.isEmpty else { return .unreadable }
            return .available(update.0)
        }
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

    private func durableLocationFixLines(
        at url: URL,
        boundary: WatchSignpostBoundary
    ) async throws -> [Data] {
        guard await self.fileWriter.fileExists(at: url) else { return [] }
        let data = try await self.fileWriter.readData(from: url)
        return self.withSynchronousActorWork(boundary) {
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            guard lines.count > 1 else { return [] }
            return lines.dropFirst().map { Data($0) }
        }
    }

    private func upsertSessionHistoryInner(
        _ entry: WatchCaptureSessionHistoryEntry,
        asOf: Date,
        boundary: WatchSignpostBoundary
    ) async throws {
        let parsed = await self.readParsedSessionHistoryEntries(boundary: boundary)
        let entries = self.withSynchronousActorWork(boundary) {
            var entriesByID = Dictionary(uniqueKeysWithValues: parsed.entries.map { ($0.sessionID, $0) })
            entriesByID[entry.sessionID] = entry
            return self.prunedSessionHistoryEntries(Array(entriesByID.values), asOf: asOf)
                .sorted { $0.startedAt < $1.startedAt }
        }
        try await self.writeSessionHistory(
            entries: entries,
            unreadableLines: parsed.unreadableLines,
            boundary: boundary
        )
    }

    private func readSessionHistoryCounterInner(
        boundary: WatchSignpostBoundary
    ) async -> WatchCaptureSessionHistoryCounter? {
        let url = self.withSynchronousActorWork(boundary) {
            self.paths.sessionHistoryCounterURL()
        }
        guard await self.fileWriter.fileExists(at: url) else { return nil }
        guard let data = try? await self.fileWriter.readData(from: url) else { return nil }
        return self.withSynchronousActorWork(boundary) {
            try? self.sessionDecoder.decode(WatchCaptureSessionHistoryCounter.self, from: data)
        }
    }

    private func writeSessionHistory(
        entries: [WatchCaptureSessionHistoryEntry],
        unreadableLines: [Data],
        boundary: WatchSignpostBoundary
    ) async throws {
        let data = try self.withSynchronousActorWork(boundary) { () -> Data in
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
            return data
        }
        try await self.fileWriter.atomicReplaceFile(at: self.paths.sessionHistoryURL(), with: data)
    }

    private func readParsedSessionHistoryEntries(boundary: WatchSignpostBoundary) async -> (
        entries: [WatchCaptureSessionHistoryEntry],
        unreadableLines: [Data],
        hadDamage: Bool,
        fileExists: Bool
    ) {
        let raw = await self.readRawSessionHistoryPopulation(boundary: boundary)
        guard raw.isReadable else {
            return ([], [], true, raw.fileExists)
        }
        return self.withSynchronousActorWork(boundary) {
            var newestByID: [String: WatchCaptureSessionHistoryEntry] = [:]
            for entry in raw.entries {
                newestByID[entry.sessionID] = entry
            }
            return (Array(newestByID.values), raw.unreadableLines, raw.hadDamage, raw.fileExists)
        }
    }

    private func readRawSessionHistoryPopulation(
        boundary: WatchSignpostBoundary
    ) async -> RawSessionHistoryPopulation {
        let url = self.withSynchronousActorWork(boundary) {
            self.paths.sessionHistoryURL()
        }
        guard await self.fileWriter.fileExists(at: url) else {
            return RawSessionHistoryPopulation(
                entries: [],
                unreadableLines: [],
                hadDamage: false,
                fileExists: false,
                isReadable: true
            )
        }
        guard let data = try? await self.fileWriter.readData(from: url) else {
            return RawSessionHistoryPopulation(
                entries: [],
                unreadableLines: [],
                hadDamage: true,
                fileExists: true,
                isReadable: false
            )
        }
        return self.withSynchronousActorWork(boundary) {
            var entries: [WatchCaptureSessionHistoryEntry] = []
            var unreadableLines: [Data] = []
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let lineData = Data(line)
                if let entry = try? self.sessionDecoder.decode(WatchCaptureSessionHistoryEntry.self, from: lineData) {
                    entries.append(entry)
                } else {
                    unreadableLines.append(lineData)
                }
            }
            return RawSessionHistoryPopulation(
                entries: entries,
                unreadableLines: unreadableLines,
                hadDamage: !unreadableLines.isEmpty,
                fileExists: true,
                isReadable: true
            )
        }
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

    private func prepareRootInner(boundary: WatchSignpostBoundary) async throws {
        let rootURL = self.withSynchronousActorWork(boundary) { self.paths.rootURL }
        try await self.fileWriter.createDirectory(at: rootURL)
    }

    private func writeManifestInner(
        _ manifest: WatchSegmentManifest,
        entry: WatchCaptureCatalogEntry?,
        ensuringDirectory: Bool
    ) async throws -> WatchCaptureCatalogEntry {
        let directory = self.withSynchronousActorWork(.storageActorManifestWrite) {
            entry?.directoryURL ?? self.paths.segmentDirectoryURL(day: manifest.day, segment: manifest.segment)
        }
        if let entry {
            let current = try await self.fileWriter.readData(from: entry.manifestURL)
            try self.withSynchronousActorWork(.storageActorManifestWrite) {
                guard current == entry.witness.manifestData else {
                    throw WatchCaptureStorageConflict.contentWitnessChanged(id: entry.id)
                }
            }
        } else if ensuringDirectory {
            try await self.prepareRootInner(boundary: .storageActorManifestWrite)
            try await self.fileWriter.createDirectory(at: directory)
        }
        let data = try self.withSynchronousActorWork(.storageActorManifestWrite) {
            try self.manifestEncoder.encode(manifest)
        }
        let manifestURL = self.withSynchronousActorWork(.storageActorManifestWrite) {
            self.paths.manifestURL(directory: directory)
        }
        try await self.fileWriter.writeData(
            data,
            to: manifestURL,
            options: .atomic
        )
        let witness = await self.contentWitness(
            manifestData: data,
            directoryURL: directory,
            boundary: .storageActorManifestWrite
        )
        return self.withSynchronousActorWork(.storageActorManifestWrite) {
            WatchCaptureCatalogEntry(
                id: entry?.id ?? WatchCaptureCatalogEntryID(day: manifest.day, segment: manifest.segment),
                directoryURL: directory,
                manifestURL: manifestURL,
                manifest: manifest,
                witness: witness
            )
        }
    }

    private func bumpRelevantMutationGeneration() {
        self.relevantMutationGeneration &+= 1
    }

    private func withTransaction<Value: Sendable>(
        transactionClass: WatchCaptureStorageTransactionClass,
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        await self.acquireTransaction(transactionClass: transactionClass)
        // This interval intentionally includes awaited file work. Domain-specific
        // signposts are emitted by `withSynchronousActorWork`, which cannot contain an
        // await and therefore measures only actor-local synchronous work.
        let elapsedInvocation = self.storageSignposter.begin(.storageActorTransactionElapsed)
        defer {
            self.storageSignposter.end(elapsedInvocation)
            self.releaseTransaction()
        }
        return try await body()
    }

    private func withCancellableTransaction<Value: Sendable>(
        transactionClass: WatchCaptureStorageTransactionClass,
        _ body: () async throws -> Value
    ) async throws -> Value {
        guard await self.acquireCancellableTransaction(transactionClass: transactionClass) else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            self.releaseTransaction()
            throw CancellationError()
        }
        let elapsedInvocation = self.storageSignposter.begin(.storageActorTransactionElapsed)
        defer {
            self.storageSignposter.end(elapsedInvocation)
            self.releaseTransaction()
        }
        return try await body()
    }

    private func withSynchronousActorWork<Value>(
        _ boundary: WatchSignpostBoundary,
        _ body: () throws -> Value
    ) rethrows -> Value {
        let invocation = self.storageSignposter.begin(boundary)
        defer { self.storageSignposter.end(invocation) }
        if invocation != nil {
            self.synchronousWorkHook(boundary)
        }
        return try body()
    }

    private func acquireTransaction(transactionClass: WatchCaptureStorageTransactionClass) async {
        guard self.transactionIsActive else {
            self.transactionIsActive = true
            self.transactionAdmissionCount += 1
            return
        }
        _ = await withCheckedContinuation { continuation in
            let waiter = TransactionWaiter(id: UUID(), continuation: continuation)
            switch transactionClass {
            case .captureSafety:
                self.captureSafetyWaiters.append(waiter)
            case .maintenance:
                self.maintenanceWaiters.append(waiter)
            }
        }
        self.transactionAdmissionCount += 1
    }

    private func acquireCancellableTransaction(
        transactionClass: WatchCaptureStorageTransactionClass
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard self.transactionIsActive else {
            self.transactionIsActive = true
            self.transactionAdmissionCount += 1
            return true
        }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let waiter = TransactionWaiter(id: id, continuation: continuation)
                switch transactionClass {
                case .captureSafety:
                    self.captureSafetyWaiters.append(waiter)
                case .maintenance:
                    self.maintenanceWaiters.append(waiter)
                }
            }
        } onCancel: {
            Task {
                await self.cancelTransactionWaiter(id: id, transactionClass: transactionClass)
            }
        }
        if acquired {
            self.transactionAdmissionCount += 1
        }
        return acquired
    }

    private func cancelTransactionWaiter(
        id: UUID,
        transactionClass: WatchCaptureStorageTransactionClass
    ) {
        switch transactionClass {
        case .captureSafety:
            guard let index = self.captureSafetyWaiters.firstIndex(where: { $0.id == id }) else { return }
            self.captureSafetyWaiters.remove(at: index).continuation.resume(returning: false)
        case .maintenance:
            guard let index = self.maintenanceWaiters.firstIndex(where: { $0.id == id }) else { return }
            self.maintenanceWaiters.remove(at: index).continuation.resume(returning: false)
        }
    }

    private func releaseTransaction() {
        if !self.captureSafetyWaiters.isEmpty {
            self.captureSafetyWaiters.removeFirst().continuation.resume(returning: true)
        } else if !self.maintenanceWaiters.isEmpty {
            self.maintenanceWaiters.removeFirst().continuation.resume(returning: true)
        } else {
            self.transactionIsActive = false
        }
    }
}
