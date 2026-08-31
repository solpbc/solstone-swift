// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let watchRelaySenderLog = Logger(subsystem: "app.solstone.swift", category: "watch-relay")

nonisolated enum WatchRelayACK {
    static let typeKey = "type"
    static let idKey = "id"
    static let type = "watch_segment_ack"

    static func userInfo(id: UUID) -> [String: Any] {
        [
            Self.typeKey: Self.type,
            Self.idKey: id.uuidString,
        ]
    }
}

@MainActor
final class WatchRelaySender {
    // 15 min — normal transfer→stage→ACK is seconds; 900s sits between the reducer
    // relay/handoff-stuck (600s) and orphan (1800s) thresholds so a stranded
    // .delivered self-heals before the orphan alarm without fighting a merely-slow ACK.
    // One constant, no config.
    private static let deliveredDeadline: TimeInterval = 900

    var onStateChanged: (@MainActor () -> Void)?

    private let storage: WatchCaptureStorage
    private let session: any WatchConnectivitySession
    private let diagnosticsStore: WatchRelayDiagnosticsStore?
    private let clock: @MainActor @Sendable () -> Date
    private let signposter: any WatchSignposting

    init(
        storage: WatchCaptureStorage,
        session: any WatchConnectivitySession,
        diagnosticsStore: WatchRelayDiagnosticsStore? = nil,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init,
        signposter: any WatchSignposting = WatchSignpost.live
    ) {
        self.storage = storage
        self.session = session
        self.diagnosticsStore = diagnosticsStore
        self.clock = clock
        self.signposter = signposter
        self.session.onReceiveUserInfo = { [weak self] userInfo in
            self?.handleUserInfo(userInfo)
        }
        self.session.onFileTransferFinished = { [weak self] completion in
            self?.handleFileTransferFinished(completion)
        }
    }

    func drain(trigger: RelayTrigger) {
        var accounting = WatchRelayDrainAccounting(
            trigger: trigger,
            activation: self.relayActivation
        )
        let interval = self.signposter.begin(
            .relayDrain,
            fields: WatchSignpostFields(trigger: trigger, activation: accounting.activation)
        )
        defer {
            self.signposter.end(interval, fields: accounting.fields)
        }

        var activeScan: WatchSignpostInvocation?
        do {
            activeScan = self.signposter.begin(.relayCleanupScan)
            let entries = try self.storage.scanManifests()
            accounting.entryWorkload = WorkloadBand.band(for: entries.count)
            var cleanupFailed = false
            for entry in entries {
                do {
                    switch entry.manifest.state {
                    case .acked, .safeToDelete:
                        try self.deleteIfSafe(entry)
                    case .delivered:
                        try self.refreshDeliveredDeadline(entry)
                    case .captured, .persisted, .finalized, .queued, .transferring:
                        break
                    }
                } catch {
                    cleanupFailed = true
                    accounting.failureCount += 1
                    watchRelaySenderLog.error(
                        "watch relay segment cleanup failed id=\(entry.manifest.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)"
                    )
                }
            }
            self.signposter.end(
                activeScan,
                fields: WatchSignpostFields(result: cleanupFailed ? .partial : .completed)
            )
            activeScan = nil

            guard self.session.activationState == .activated else { return }

            activeScan = self.signposter.begin(.relayQueueReconciliation)
            let refreshedEntries = try self.storage.scanManifests()
            accounting.refreshedWorkload = WorkloadBand.band(for: refreshedEntries.count)
            accounting.transferCandidateCount = refreshedEntries.reduce(into: 0) { count, entry in
                if entry.manifest.state == .queued || entry.manifest.state == .transferring {
                    count += 1
                }
            }
            let observations = self.session.outstandingFileTransfers
            let outstanding = self.groupedOutstandingFileTransfers(observations)
            if !self.recordQueueReconciliation(entries: refreshedEntries, observations: observations) {
                accounting.failureCount += 1
            }
            self.signposter.end(
                activeScan,
                fields: WatchSignpostFields(result: accounting.failureCount > 0 ? .partial : .completed)
            )
            activeScan = nil
            var manifestStatesByID: [UUID: WatchSegmentState] = [:]
            for entry in refreshedEntries {
                manifestStatesByID[entry.manifest.id] = entry.manifest.state
            }

            for entry in refreshedEntries {
                let group = outstanding.grouped[entry.manifest.id] ?? []
                let transition = self.signposter.begin(.relaySegmentTransition)
                do {
                    switch entry.manifest.state {
                    case .queued:
                        if group.isEmpty {
                            try self.promoteAndTransfer(entry: entry, accounting: &accounting)
                        } else {
                            try self.adoptAsTransferring(entry)
                            self.cancelRedundant(group)
                        }
                    case .transferring:
                        if group.isEmpty {
                            try self.transfer(
                                directoryURL: entry.directoryURL,
                                manifest: entry.manifest,
                                accounting: &accounting
                            )
                        } else {
                            self.cancelRedundant(group)
                        }
                    case .captured, .persisted, .finalized, .delivered, .acked, .safeToDelete:
                        break
                    }
                    self.signposter.end(transition, fields: WatchSignpostFields(result: .completed))
                } catch {
                    accounting.failureCount += 1
                    self.signposter.end(transition, fields: WatchSignpostFields(result: .failed))
                    watchRelaySenderLog.error(
                        "watch relay segment drain failed id=\(entry.manifest.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)"
                    )
                }
            }

            for id in outstanding.orderedIDs {
                guard let group = outstanding.grouped[id] else { continue }
                guard let id else {
                    self.cancelAll(group)
                    continue
                }
                guard let state = manifestStatesByID[id] else {
                    self.cancelAll(group)
                    continue
                }
                if state != .queued && state != .transferring {
                    self.cancelAll(group)
                }
            }
        } catch {
            accounting.fatalFailure = true
            accounting.failureCount += 1
            if accounting.entryWorkload == .notSampled {
                accounting.entryWorkload = .unknown
            } else {
                accounting.refreshedWorkload = .unknown
            }
            self.signposter.end(activeScan, fields: WatchSignpostFields(result: .failed))
            watchRelaySenderLog.error("watch relay drain failed: \(String(describing: error), privacy: .public)")
        }
    }

    func bundleURL(for id: UUID) -> URL {
        self.bundleDirectoryURL()
            .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
    }
}

private extension WatchRelaySender {
    func handleUserInfo(_ userInfo: [String: Any]) {
        guard userInfo[WatchRelayACK.typeKey] as? String == WatchRelayACK.type,
              let idString = userInfo[WatchRelayACK.idKey] as? String,
              let id = UUID(uuidString: idString)
        else {
            return
        }

        do {
            try self.acknowledge(id: id)
            self.drain(trigger: .durableACK)
        } catch {
            watchRelaySenderLog.error("watch relay ack failed: \(String(describing: error), privacy: .public)")
        }
    }

    func handleFileTransferFinished(_ completion: WatchConnectivityFileTransferCompletion) {
        do {
            guard let id = completion.segmentID else { return }
            let entries = try self.storage.scanManifests()
            guard let entry = entries.first(where: { $0.manifest.id == id }) else { return }
            var manifest = entry.manifest
            if let failure = completion.failure {
                guard manifest.state == .transferring else { return }
                manifest.state = .queued
                try self.storage.writeManifest(manifest, in: entry.directoryURL)
                self.notifyStateChanged()
                self.diagnosticsStore?.recordTransferCompletion(
                    manifest: manifest,
                    directoryURL: entry.directoryURL,
                    succeeded: false,
                    failure: failure,
                    at: self.clock()
                )
                watchRelaySenderLog.notice(
                    "watch relay transfer failed id=\(id.uuidString, privacy: .public): \(failure.boundedRedactedDescription, privacy: .public)"
                )
                return
            }

            guard manifest.state == .transferring || manifest.state == .queued else { return }
            manifest.state = .delivered
            manifest.deliveredAt = self.clock()
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
            self.diagnosticsStore?.recordTransferCompletion(
                manifest: manifest,
                directoryURL: entry.directoryURL,
                succeeded: true,
                failure: nil,
                at: self.clock()
            )
        } catch {
            watchRelaySenderLog.error("watch relay finish handling failed: \(String(describing: error), privacy: .public)")
        }
    }

    func acknowledge(id: UUID) throws {
        let entries = try self.storage.scanManifests()
        guard let entry = entries.first(where: { $0.manifest.id == id }) else {
            try? self.storage.fileWriter.removeItem(at: self.bundleURL(for: id))
            return
        }

        var manifest = entry.manifest
        if manifest.state != .acked, manifest.state != .safeToDelete {
            manifest.state = .acked
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
        }
        self.diagnosticsStore?.recordDurableACK(
            manifest: manifest,
            directoryURL: entry.directoryURL,
            at: self.clock()
        )

        manifest.state = .safeToDelete
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
        try self.storage.fileWriter.removeItem(at: entry.directoryURL)
        try? self.storage.fileWriter.removeItem(at: self.bundleURL(for: id))
        self.notifyStateChanged()
    }

    func deleteIfSafe(_ entry: WatchCaptureStorage.ManifestEntry) throws {
        var manifest = entry.manifest
        if manifest.state == .acked {
            manifest.state = .safeToDelete
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
        }
        try self.storage.fileWriter.removeItem(at: entry.directoryURL)
        try? self.storage.fileWriter.removeItem(at: self.bundleURL(for: manifest.id))
        self.notifyStateChanged()
    }

    func refreshDeliveredDeadline(_ entry: WatchCaptureStorage.ManifestEntry) throws {
        guard entry.manifest.state == .delivered else { return }
        var manifest = entry.manifest
        let now = self.clock()

        guard let deliveredAt = manifest.deliveredAt else {
            manifest.deliveredAt = now
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
            return
        }

        guard now.timeIntervalSince(deliveredAt) >= Self.deliveredDeadline else {
            return
        }

        manifest.state = .queued
        manifest.deliveredAt = nil
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
    }

    func promoteAndTransfer(
        entry: WatchCaptureStorage.ManifestEntry,
        accounting: inout WatchRelayDrainAccounting
    ) throws {
        var manifest = entry.manifest
        manifest.state = .transferring
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
        try self.transfer(directoryURL: entry.directoryURL, manifest: manifest, accounting: &accounting)
    }

    func adoptAsTransferring(_ entry: WatchCaptureStorage.ManifestEntry) throws {
        guard entry.manifest.state == .queued else { return }
        var manifest = entry.manifest
        manifest.state = .transferring
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
    }

    func transfer(
        directoryURL: URL,
        manifest: WatchSegmentManifest,
        accounting: inout WatchRelayDrainAccounting
    ) throws {
        let bundleURL = self.bundleURL(for: manifest.id)
        let bundleInterval = self.signposter.begin(.relayBundleWrite)
        var bundleCleanupFailed = false
        do {
            try self.storage.fileWriter.removeItem(at: bundleURL)
        } catch {
            bundleCleanupFailed = true
            accounting.failureCount += 1
        }
        do {
            try WatchSegmentBundleCodec.writeBundle(
                segmentDirectory: directoryURL,
                storage: self.storage,
                to: bundleURL
            )
            self.signposter.end(
                bundleInterval,
                fields: WatchSignpostFields(result: bundleCleanupFailed ? .partial : .completed)
            )
        } catch {
            self.signposter.end(bundleInterval, fields: WatchSignpostFields(result: .failed))
            throw error
        }
        let attemptRecord = WatchRelayAttemptRecord(
            segmentID: manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: self.clock()
        )
        let attemptURL = self.attemptURL(directoryURL: directoryURL)
        let attemptInterval = self.signposter.begin(.relayAttemptPersistence)
        do {
            let data = try WatchRelayAttemptRecord.makeEncoder().encode(attemptRecord)
            try self.storage.fileWriter.writeData(data, to: attemptURL, options: .atomic)
            self.signposter.end(attemptInterval, fields: WatchSignpostFields(result: .completed))
            let enqueueInterval = self.signposter.begin(.relayTransferEnqueue)
            self.session.transferFile(
                bundleURL,
                metadata: WatchSegmentBundleCodec.metadata(for: manifest, attempt: attemptRecord.tag)
            )
            self.signposter.end(enqueueInterval, fields: WatchSignpostFields(result: .completed))
        } catch {
            accounting.failureCount += 1
            self.signposter.end(
                attemptInterval,
                fields: WatchSignpostFields(result: .failed, usedFallback: true)
            )
            do {
                try self.storage.fileWriter.removeItem(at: attemptURL)
            } catch {
                accounting.failureCount += 1
            }
            let failure = WatchConnectivityTransferFailureSnapshot(error: error)
            watchRelaySenderLog.error(
                "watch relay attempt record write failed id=\(manifest.id.uuidString, privacy: .public): \(failure.boundedRedactedDescription, privacy: .public)"
            )
            let enqueueInterval = self.signposter.begin(.relayTransferEnqueue)
            self.session.transferFile(bundleURL, metadata: WatchSegmentBundleCodec.metadata(for: manifest))
            self.signposter.end(
                enqueueInterval,
                fields: WatchSignpostFields(result: .completed, usedFallback: true)
            )
        }
        let diagnosticsInterval = self.signposter.begin(.relayDiagnosticsPersistence)
        let diagnosticsSucceeded = self.diagnosticsStore?.recordEnqueue(
            manifest: manifest,
            directoryURL: directoryURL,
            bundleURL: bundleURL,
            at: self.clock()
        )
        if diagnosticsSucceeded == false {
            accounting.failureCount += 1
        }
        self.signposter.end(
            diagnosticsInterval,
            fields: WatchSignpostFields(result: diagnosticsSucceeded == false ? .failed : .completed)
        )
        watchRelaySenderLog.info("watch relay transfer enqueued id=\(manifest.id.uuidString, privacy: .public)")
    }

    func bundleDirectoryURL() -> URL {
        self.storage.rootURL.appendingPathComponent(".relay-bundles", isDirectory: true)
    }

    func attemptURL(directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(WatchRelayAttemptRecord.filename, isDirectory: false)
    }

    func groupedOutstandingFileTransfers(_ observations: [WatchConnectivityFileTransferObservation]) -> (
        grouped: Dictionary<UUID?, [WatchConnectivityFileTransferObservation]>,
        orderedIDs: [UUID?]
    ) {
        var grouped: Dictionary<UUID?, [WatchConnectivityFileTransferObservation]> = [:]
        var orderedIDs: [UUID?] = []
        for observation in observations {
            let id = observation.snapshot.segmentID
            if grouped[id] == nil {
                orderedIDs.append(id)
            }
            grouped[id, default: []].append(observation)
        }
        return (grouped, orderedIDs)
    }

    func cancelRedundant(_ group: [WatchConnectivityFileTransferObservation]) {
        guard group.count > 1 else { return }
        self.cancelAll(Array(group.dropFirst()))
    }

    func cancelAll(_ transfers: [WatchConnectivityFileTransferObservation]) {
        for transfer in transfers {
            transfer.cancel()
        }
    }

    func recordQueueReconciliation(
        entries: [WatchCaptureStorage.ManifestEntry],
        observations: [WatchConnectivityFileTransferObservation]
    ) -> Bool {
        guard let diagnosticsStore else { return true }
        let activeEntries = entries.filter { entry in
            entry.manifest.state == .queued || entry.manifest.state == .transferring
        }
        let snapshots = observations.map(\.snapshot)
        let counts = WatchRelayDiagnosticsCollector.reconciliationCounts(
            activeManifestIDs: Set(activeEntries.map(\.manifest.id)),
            fileTransfers: snapshots
        )
        return diagnosticsStore.recordQueueReconciliation(
            counts: counts,
            observedFileTransferCount: snapshots.count,
            activeManifestCount: activeEntries.count,
            at: self.clock()
        )
    }

    func notifyStateChanged() {
        self.onStateChanged?()
    }
}

private extension WatchRelaySender {
    var relayActivation: RelayActivation {
        self.session.activationState == .activated ? .activated : .notActivated
    }
}

private struct WatchRelayDrainAccounting {
    let trigger: RelayTrigger
    let activation: RelayActivation
    var entryWorkload: WorkloadBand = .notSampled
    var refreshedWorkload: WorkloadBand = .notSampled
    var transferCandidateCount: Int?
    var failureCount = 0
    var fatalFailure = false

    var result: RelayResult {
        if self.fatalFailure { return .failed }
        return self.failureCount == 0 ? .completed : .partial
    }

    var fields: WatchSignpostFields {
        WatchSignpostFields(
            trigger: self.trigger,
            result: self.result,
            activation: self.activation,
            entryWorkload: self.entryWorkload,
            refreshedWorkload: self.refreshedWorkload,
            transferCandidateCount: self.transferCandidateCount,
            failureCount: self.failureCount
        )
    }
}
