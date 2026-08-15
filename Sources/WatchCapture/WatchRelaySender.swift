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
    private let recoveryRouteStore: WatchRelayRecoveryRouteStore
    private let clock: @MainActor @Sendable () -> Date

    init(
        storage: WatchCaptureStorage,
        session: any WatchConnectivitySession,
        diagnosticsStore: WatchRelayDiagnosticsStore? = nil,
        recoveryRouteStore: WatchRelayRecoveryRouteStore? = nil,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        self.storage = storage
        self.session = session
        self.diagnosticsStore = diagnosticsStore
        self.recoveryRouteStore = recoveryRouteStore ?? WatchRelayRecoveryRouteStore(storage: storage)
        self.clock = clock
        self.session.onReceiveUserInfo = { [weak self] userInfo in
            self?.handleUserInfo(userInfo)
        }
        self.session.onFileTransferFinished = { [weak self] completion in
            self?.handleFileTransferFinished(completion)
        }
    }

    func drain() {
        do {
            let entries = try self.storage.scanManifests()
            for entry in entries {
                switch entry.manifest.state {
                case .acked, .safeToDelete:
                    try self.deleteIfSafe(entry)
                case .delivered:
                    try self.refreshDeliveredDeadline(entry)
                case .captured, .persisted, .finalized, .queued, .transferring:
                    break
                }
            }

            self.recoveryRouteStore.establishRecord()

            guard self.session.activationState == .activated else { return }

            let refreshedEntries = try self.storage.scanManifests()
            let observations = self.session.outstandingFileTransfers
            let outstanding = self.groupedOutstandingFileTransfers(observations)
            self.recordQueueReconciliation(entries: refreshedEntries, observations: observations)
            var manifestStatesByID: [UUID: WatchSegmentState] = [:]
            for entry in refreshedEntries {
                manifestStatesByID[entry.manifest.id] = entry.manifest.state
            }

            for entry in refreshedEntries {
                let group = outstanding.grouped[entry.manifest.id] ?? []
                switch entry.manifest.state {
                case .queued:
                    if group.isEmpty {
                        try self.promoteAndTransfer(entry: entry)
                    } else {
                        try self.adoptAsTransferring(entry)
                        self.cancelRedundant(group)
                    }
                case .transferring:
                    if group.isEmpty {
                        try self.transfer(directoryURL: entry.directoryURL, manifest: entry.manifest)
                    } else {
                        self.cancelRedundant(group)
                    }
                case .captured, .persisted, .finalized, .delivered, .acked, .safeToDelete:
                    break
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
            self.drain()
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
            self.recoveryRouteStore.recordSuccessfulTransfer()
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
        let newlyAppliedACK = manifest.state != .acked && manifest.state != .safeToDelete
        if newlyAppliedACK {
            manifest.state = .acked
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
            self.recoveryRouteStore.recordDurableACK()
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

    func promoteAndTransfer(entry: WatchCaptureStorage.ManifestEntry) throws {
        var manifest = entry.manifest
        manifest.state = .transferring
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
        try self.transfer(directoryURL: entry.directoryURL, manifest: manifest)
    }

    func adoptAsTransferring(_ entry: WatchCaptureStorage.ManifestEntry) throws {
        guard entry.manifest.state == .queued else { return }
        var manifest = entry.manifest
        manifest.state = .transferring
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
    }

    func transfer(directoryURL: URL, manifest: WatchSegmentManifest) throws {
        let bundleURL = self.bundleURL(for: manifest.id)
        try? self.storage.fileWriter.removeItem(at: bundleURL)
        try WatchSegmentBundleCodec.writeBundle(
            segmentDirectory: directoryURL,
            storage: self.storage,
            to: bundleURL
        )
        let attemptRecord = WatchRelayAttemptRecord(
            segmentID: manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: self.clock()
        )
        let attemptURL = self.attemptURL(directoryURL: directoryURL)
        do {
            let data = try WatchRelayAttemptRecord.makeEncoder().encode(attemptRecord)
            try self.storage.fileWriter.writeData(data, to: attemptURL, options: .atomic)
            self.session.transferFile(bundleURL, metadata: WatchSegmentBundleCodec.metadata(for: manifest, attempt: attemptRecord.tag))
        } catch {
            try? self.storage.fileWriter.removeItem(at: attemptURL)
            let failure = WatchConnectivityTransferFailureSnapshot(error: error)
            watchRelaySenderLog.error(
                "watch relay attempt record write failed id=\(manifest.id.uuidString, privacy: .public): \(failure.boundedRedactedDescription, privacy: .public)"
            )
            self.session.transferFile(bundleURL, metadata: WatchSegmentBundleCodec.metadata(for: manifest))
        }
        self.diagnosticsStore?.recordEnqueue(
            manifest: manifest,
            directoryURL: directoryURL,
            bundleURL: bundleURL,
            at: self.clock()
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
    ) {
        guard let diagnosticsStore else { return }
        let activeEntries = entries.filter { entry in
            entry.manifest.state == .queued || entry.manifest.state == .transferring
        }
        let snapshots = observations.map(\.snapshot)
        let counts = WatchRelayDiagnosticsCollector.reconciliationCounts(
            activeManifestIDs: Set(activeEntries.map(\.manifest.id)),
            fileTransfers: snapshots
        )
        diagnosticsStore.recordQueueReconciliation(
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
