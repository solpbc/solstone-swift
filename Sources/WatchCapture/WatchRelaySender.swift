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

    private let paths: WatchCaptureStoragePaths
    private let storageActor: WatchCaptureStorageActor
    private let session: any WatchConnectivitySession
    private let clock: @MainActor @Sendable () -> Date
    private let signposter: any WatchSignposting
    private var relayCallbackTail: Task<Void, Never> = Task {}
    private var drainOwnerTask: Task<Void, Never>?
    private var queuedDrainTask: Task<Void, Never>?
    private var queuedDrainTrigger: RelayTrigger?

    init(
        paths: WatchCaptureStoragePaths,
        storageActor: WatchCaptureStorageActor,
        session: any WatchConnectivitySession,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init,
        signposter: any WatchSignposting = WatchSignpost.live
    ) {
        self.paths = paths
        self.storageActor = storageActor
        self.session = session
        self.clock = clock
        self.signposter = signposter
        self.session.onReceiveUserInfo = { [weak self] userInfo in
            self?.enqueueRelayCallback { [weak self] in
                await self?.handleUserInfo(userInfo)
            }
        }
        self.session.onFileTransferFinished = { [weak self] completion in
            self?.enqueueRelayCallback { [weak self] in
                await self?.handleFileTransferFinished(completion)
            }
        }
    }

    func requestDrain(trigger: RelayTrigger) async {
        let request = self.signposter.begin(
            .relayDrainRequest,
            fields: WatchSignpostFields(trigger: trigger)
        )
        if let queuedDrainTask = self.queuedDrainTask {
            self.queuedDrainTrigger = trigger
            self.signposter.end(
                request,
                fields: WatchSignpostFields(trigger: trigger, result: .mergedFollowUp)
            )
            await queuedDrainTask.value
            return
        }
        if let drainOwnerTask = self.drainOwnerTask {
            self.queuedDrainTrigger = trigger
            let followUp = Task { @MainActor [weak self] in
                await drainOwnerTask.value
                guard let self else { return }
                let resolvedTrigger = self.queuedDrainTrigger ?? trigger
                // Clear the queued state before B begins. A request arriving
                // while B is running must therefore schedule C, not merge into B.
                self.queuedDrainTrigger = nil
                self.queuedDrainTask = nil
                await self.startOwnedDrainPass(trigger: resolvedTrigger)
            }
            self.queuedDrainTask = followUp
            self.signposter.end(
                request,
                fields: WatchSignpostFields(trigger: trigger, result: .scheduledFollowUp)
            )
            await followUp.value
            return
        }

        self.signposter.end(
            request,
            fields: WatchSignpostFields(trigger: trigger, result: .becameOwner)
        )
        await self.startOwnedDrainPass(trigger: trigger)
    }

    private func startOwnedDrainPass(trigger: RelayTrigger) async {
        let owner = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runOwnedDrainPass(trigger: trigger)
        }
        self.drainOwnerTask = owner
        await owner.value
    }

    private func runOwnedDrainPass(trigger: RelayTrigger) async {
        defer { self.drainOwnerTask = nil }
        await self.drainPass(trigger: trigger)
    }

    private func drainPass(trigger: RelayTrigger) async {
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
            var catalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
            accounting.recordCatalog(rootState: catalog.rootState)
            let entries = catalog.entries
            let catalogResult = self.catalogResult(catalog.rootState)
            accounting.entryWorkload = self.workloadBand(for: catalog)
            var cleanupFailed = false
            var successfulBumps: UInt64 = 0
            for entry in entries {
                do {
                    switch entry.manifest.state {
                    case .acked, .safeToDelete:
                        let originalState = entry.manifest.state
                        try await self.deleteIfSafe(entry)
                        catalog = catalog.removingEntry(manifestID: entry.manifest.id)
                        successfulBumps += originalState == .acked ? 2 : 1
                    case .delivered:
                        let transition = try await self.refreshDeliveredDeadline(entry)
                        if transition.didChange {
                            catalog = catalog.replacingEntry(transition.entry)
                            successfulBumps += 1
                        }
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
                fields: WatchSignpostFields(
                    result: catalogResult == .failed ? .failed : (cleanupFailed ? .partial : catalogResult)
                )
            )
            activeScan = nil

            guard self.session.activationState == .activated else { return }

            activeScan = self.signposter.begin(.relayQueueReconciliation)
            let reusedCatalog = catalog
            let fallbackNeeded = await self.storageActor.needsCatalogFallbackRescan(
                snapshot: reusedCatalog,
                successfulBumps: successfulBumps
            )
            let refreshedCatalog: WatchCaptureCatalog
            if fallbackNeeded {
                refreshedCatalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
            } else {
                refreshedCatalog = reusedCatalog
            }
            accounting.recordCatalog(rootState: refreshedCatalog.rootState)
            let refreshedEntries = refreshedCatalog.entries
            let refreshedCatalogResult = self.catalogResult(refreshedCatalog.rootState)
            accounting.refreshedWorkload = self.workloadBand(for: refreshedCatalog)
            accounting.transferCandidateCount = refreshedCatalog.canInferUUIDAbsence
                ? refreshedEntries.reduce(into: 0) { count, entry in
                    if entry.manifest.state == .queued || entry.manifest.state == .transferring {
                        count += 1
                    }
                }
                : nil
            let observations = self.session.outstandingFileTransfers
            let outstanding = self.groupedOutstandingFileTransfers(observations)
            if !(await self.recordQueueReconciliation(entries: refreshedEntries, observations: observations)) {
                accounting.failureCount += 1
            }
            self.signposter.end(
                activeScan,
                fields: WatchSignpostFields(
                    result: fallbackNeeded
                        ? (refreshedCatalogResult == .failed
                            ? .failed
                            : (accounting.failureCount > 0 ? .partial : refreshedCatalogResult))
                        : .cached
                )
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
                            try await self.promoteAndTransfer(entry: entry, accounting: &accounting)
                        } else {
                            try await self.adoptAsTransferring(entry)
                            self.cancelRedundant(group)
                        }
                    case .transferring:
                        if group.isEmpty {
                            try await self.transfer(entry: entry, accounting: &accounting)
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
                    if refreshedCatalog.canInferUUIDAbsence {
                        self.cancelAll(group)
                    }
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
    func enqueueRelayCallback(_ operation: @escaping @MainActor () async -> Void) {
        let previous = self.relayCallbackTail
        self.relayCallbackTail = Task { @MainActor in
            await previous.value
            await operation()
        }
    }

    func handleUserInfo(_ userInfo: [String: Any]) async {
        guard userInfo[WatchRelayACK.typeKey] as? String == WatchRelayACK.type,
              let idString = userInfo[WatchRelayACK.idKey] as? String,
              let id = UUID(uuidString: idString)
        else {
            return
        }

        do {
            try await self.acknowledge(id: id)
            await self.requestDrain(trigger: .durableACK)
        } catch {
            watchRelaySenderLog.error("watch relay ack failed: \(String(describing: error), privacy: .public)")
        }
    }

    func handleFileTransferFinished(_ completion: WatchConnectivityFileTransferCompletion) async {
        do {
            guard let id = completion.segmentID else { return }
            let catalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
            guard let entry = catalog.entries.first(where: { $0.manifest.id == id }) else { return }
            if let failure = completion.failure {
                guard entry.manifest.state == .transferring else { return }
                let transition = try await self.storageActor.requeueFailedRelayTransfer(entry)
                guard transition.didChange else { return }
                await self.storageActor.recordRelayTransferCompletion(
                    manifest: transition.entry.manifest,
                    directoryURL: transition.entry.directoryURL,
                    succeeded: false,
                    failure: failure,
                    at: self.clock()
                )
                self.notifyStateChanged()
                watchRelaySenderLog.notice(
                    "watch relay transfer failed id=\(id.uuidString, privacy: .public): \(failure.boundedRedactedDescription, privacy: .public)"
                )
                return
            }

            guard entry.manifest.state == .transferring || entry.manifest.state == .queued else { return }
            let transition = try await self.storageActor.markRelayTransferDelivered(entry, at: self.clock())
            guard transition.didChange else { return }
            await self.storageActor.recordRelayTransferCompletion(
                manifest: transition.entry.manifest,
                directoryURL: transition.entry.directoryURL,
                succeeded: true,
                failure: nil,
                at: self.clock()
            )
            self.notifyStateChanged()
        } catch {
            watchRelaySenderLog.error("watch relay finish handling failed: \(String(describing: error), privacy: .public)")
        }
    }

    func acknowledge(id: UUID) async throws {
        let catalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
        guard let entry = catalog.entries.first(where: { $0.manifest.id == id }) else {
            if catalog.canInferUUIDAbsence {
                try? await self.storageActor.removeItem(
                    at: self.bundleURL(for: id),
                    transactionClass: .maintenance
                )
            }
            return
        }

        let acknowledged = try await self.storageActor.acknowledgeRelaySegment(entry)
        await self.storageActor.recordRelayDurableACK(
            manifest: acknowledged.entry.manifest,
            directoryURL: acknowledged.entry.directoryURL,
            at: self.clock()
        )

        do {
            let safe = try await self.storageActor.markRelaySegmentSafeToDelete(acknowledged.entry)
            try await self.storageActor.deleteAcknowledgedRelaySegment(safe.entry, bundleURL: self.bundleURL(for: id))
        } catch {
            self.notifyStateChanged()
            throw error
        }
        self.notifyStateChanged()
    }

    func deleteIfSafe(_ entry: WatchCaptureCatalogEntry) async throws {
        let safe = try await self.storageActor.markRelaySegmentSafeToDelete(entry)
        do {
            try await self.storageActor.deleteAcknowledgedRelaySegment(
                safe.entry,
                bundleURL: self.bundleURL(for: safe.entry.manifest.id)
            )
        } catch {
            if safe.didChange {
                self.notifyStateChanged()
            }
            throw error
        }
        self.notifyStateChanged()
    }

    func refreshDeliveredDeadline(_ entry: WatchCaptureCatalogEntry) async throws -> WatchRelayStorageTransition {
        guard entry.manifest.state == .delivered else {
            return WatchRelayStorageTransition(entry: entry, didChange: false)
        }
        let transition = try await self.storageActor.refreshRelayDeliveredDeadline(
            entry,
            at: self.clock(),
            deadline: Self.deliveredDeadline
        )
        if transition.didChange {
            self.notifyStateChanged()
        }
        return transition
    }

    func promoteAndTransfer(
        entry: WatchCaptureCatalogEntry,
        accounting: inout WatchRelayDrainAccounting
    ) async throws {
        let transition = try await self.storageActor.promoteQueuedForRelay(entry)
        do {
            try await self.transfer(entry: transition.entry, accounting: &accounting)
        } catch {
            self.notifyStateChanged()
            throw error
        }
        self.notifyStateChanged()
    }

    func adoptAsTransferring(_ entry: WatchCaptureCatalogEntry) async throws {
        let transition = try await self.storageActor.adoptQueuedForRelay(entry)
        if transition.didChange {
            self.notifyStateChanged()
        }
    }

    func transfer(
        entry: WatchCaptureCatalogEntry,
        accounting: inout WatchRelayDrainAccounting
    ) async throws {
        let manifest = entry.manifest
        let bundleURL = self.bundleURL(for: manifest.id)
        let bundleInterval = self.signposter.begin(.relayBundleWrite)
        let attemptRecord = WatchRelayAttemptRecord(
            segmentID: manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: self.clock()
        )
        let preparation: WatchRelayTransferPreparation
        do {
            preparation = try await self.storageActor.prepareRelayTransfer(
                entry,
                bundleURL: bundleURL,
                attempt: attemptRecord
            )
            if preparation.bundleCleanupFailed {
                accounting.failureCount += 1
            }
            if preparation.receiptPersistenceFailed {
                accounting.failureCount += 1
            }
            let result: RelayResult
            if preparation.disposition == .reused {
                result = .cached
            } else if preparation.bundleCleanupFailed || preparation.receiptPersistenceFailed {
                result = .partial
            } else {
                result = .completed
            }
            self.signposter.end(
                bundleInterval,
                fields: WatchSignpostFields(
                    result: result,
                    wholeFileReadCount: preparation.wholeFileReads.count,
                    wholeFileReadByteCount: preparation.wholeFileReads.byteCount
                )
            )
        } catch {
            self.signposter.end(bundleInterval, fields: WatchSignpostFields(result: .failed))
            throw error
        }
        let attemptInterval = self.signposter.begin(.relayAttemptPersistence)
        if let attempt = preparation.attempt {
            self.signposter.end(attemptInterval, fields: WatchSignpostFields(result: .completed))
            let enqueueInterval = self.signposter.begin(.relayTransferEnqueue)
            self.session.transferFile(
                preparation.bundleURL,
                metadata: WatchSegmentBundleCodec.metadata(for: preparation.manifest, attempt: attempt.tag)
            )
            self.signposter.end(enqueueInterval, fields: WatchSignpostFields(result: .completed))
        } else {
            accounting.failureCount += 1
            self.signposter.end(
                attemptInterval,
                fields: WatchSignpostFields(result: .failed, usedFallback: true)
            )
            if preparation.attemptCleanupFailed {
                accounting.failureCount += 1
            }
            let failure = preparation.attemptFailure ?? WatchConnectivityTransferFailureSnapshot(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                boundedRedactedDescription: "unknown attempt persistence failure"
            )
            watchRelaySenderLog.error(
                "watch relay attempt record write failed id=\(manifest.id.uuidString, privacy: .public): \(failure.boundedRedactedDescription, privacy: .public)"
            )
            let enqueueInterval = self.signposter.begin(.relayTransferEnqueue)
            self.session.transferFile(preparation.bundleURL, metadata: WatchSegmentBundleCodec.metadata(for: preparation.manifest))
            self.signposter.end(
                enqueueInterval,
                fields: WatchSignpostFields(result: .completed, usedFallback: true)
            )
        }
        let diagnosticsInterval = self.signposter.begin(.relayDiagnosticsPersistence)
        let diagnosticsSucceeded = await self.storageActor.recordRelayEnqueue(
            manifest: preparation.manifest,
            directoryURL: entry.directoryURL,
            bundleURL: preparation.bundleURL,
            at: self.clock()
        )
        if diagnosticsSucceeded == false {
            accounting.failureCount += 1
        }
        self.signposter.end(
            diagnosticsInterval,
            fields: WatchSignpostFields(result: diagnosticsSucceeded == false ? .failed : .completed)
        )
        watchRelaySenderLog.info("watch relay transfer enqueued id=\(preparation.manifest.id.uuidString, privacy: .public)")
    }

    func bundleDirectoryURL() -> URL {
        self.paths.rootURL.appendingPathComponent(".relay-bundles", isDirectory: true)
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
        entries: [WatchCaptureCatalogEntry],
        observations: [WatchConnectivityFileTransferObservation]
    ) async -> Bool {
        let activeEntries = entries.filter { entry in
            entry.manifest.state == .queued || entry.manifest.state == .transferring
        }
        let snapshots = observations.map(\.snapshot)
        let counts = WatchRelayDiagnosticsCollector.reconciliationCounts(
            activeManifestIDs: Set(activeEntries.map(\.manifest.id)),
            fileTransfers: snapshots
        )
        return await self.storageActor.recordRelayQueueReconciliation(
            counts: counts,
            observedFileTransferCount: snapshots.count,
            activeManifestCount: activeEntries.count,
            at: self.clock()
        )
    }

    func workloadBand(for catalog: WatchCaptureCatalog) -> WorkloadBand {
        guard catalog.canInferUUIDAbsence else { return .unknown }
        return WorkloadBand.band(for: catalog.entries.count)
    }

    func catalogResult(_ rootState: WatchCaptureCatalogRootState) -> RelayResult {
        switch rootState {
        case .complete, .emptyComplete:
            .completed
        case .partial:
            .partial
        case .unavailable:
            .failed
        }
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
    private var catalogResult: RelayResult = .completed

    init(trigger: RelayTrigger, activation: RelayActivation) {
        self.trigger = trigger
        self.activation = activation
    }

    var result: RelayResult {
        if self.fatalFailure || self.catalogResult == .failed { return .failed }
        if self.failureCount > 0 || self.catalogResult == .partial { return .partial }
        return .completed
    }

    mutating func recordCatalog(rootState: WatchCaptureCatalogRootState) {
        switch rootState {
        case .unavailable:
            self.catalogResult = .failed
        case .partial where self.catalogResult == .completed:
            self.catalogResult = .partial
        case .complete, .emptyComplete, .partial:
            break
        }
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
