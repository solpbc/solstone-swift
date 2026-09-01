// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import WidgetKit

private let watchCaptureModelLog = Logger(subsystem: "app.solstone.swift", category: "watch-capture")

struct WatchDiagnosticsPublicationCache {
    var envelopeData: Data?
    private(set) var generation: UInt64 = 0
    private(set) var acceptedGeneration: UInt64?

    init(envelopeData: Data?) {
        self.envelopeData = envelopeData
    }

    var owedUntilAccepted: Bool {
        self.acceptedGeneration != self.generation
    }

    var publication: (envelopeData: Data?, generation: UInt64) {
        (self.envelopeData, self.generation)
    }

    mutating func replaceEnvelope(_ envelopeData: Data?) {
        self.generation &+= 1
        self.envelopeData = envelopeData
    }

    mutating func markAccepted(envelopeData: Data?, generation: UInt64) {
        guard envelopeData != nil,
              generation == self.generation,
              envelopeData == self.envelopeData
        else { return }
        self.acceptedGeneration = generation
    }
}

@MainActor
@Observable
final class WatchCaptureModel {
    var presentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0) {
        didSet {
            guard oldValue != self.presentation else { return }
            self.enqueueComplicationSnapshotPublication()
        }
    }

    @ObservationIgnored private var engine: WatchCaptureEngine?
    @ObservationIgnored private var storageActor: WatchCaptureStorageActor?
    @ObservationIgnored private let diagnosticsCollector: WatchRelayDiagnosticsCollector?
    @ObservationIgnored private let signposter: any WatchSignposting
    @ObservationIgnored private let complicationRootURL: @MainActor () throws -> URL
    @ObservationIgnored private let reloadComplicationTimelines: @MainActor () -> Void
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private var complicationPublishTail: Task<Void, Never> = Task {}
    @ObservationIgnored private var diagnosticsPublicationCache = WatchDiagnosticsPublicationCache(envelopeData: nil)
    @ObservationIgnored private var diagnosticsPublicationGeneration: UInt64?
    @ObservationIgnored private var refreshCoordinatorTask: Task<Void, Never>?
    @ObservationIgnored private var relayStateRefreshRequested = false
    @ObservationIgnored private var relayStateRefreshPassActive = false
    @ObservationIgnored private var relayStateRefreshFollowUpRequested = false
    @ObservationIgnored private var diagnosticsRefreshRequested = false
    @ObservationIgnored private var diagnosticsRefreshPassActive = false
    @ObservationIgnored private var diagnosticsRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var completedDiagnosticsRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var recoveryReloadOwed = true
    @ObservationIgnored private var complicationRewriteOwed = false

    var diagnosticsEnvelopeOwedUntilAccepted: Bool {
        self.diagnosticsPublicationCache.owedUntilAccepted
    }

    init(
        paths: WatchCaptureStoragePaths,
        storageActor: WatchCaptureStorageActor,
        relaySender: WatchRelaySender,
        session: any WatchConnectivitySession,
        diagnosticsCollector: WatchRelayDiagnosticsCollector,
        notificationScheduler: any WatchNotificationScheduling,
        environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding,
        clock: any ObserverClock = SystemObserverClock(),
        signposter: any WatchSignposting = WatchSignpost.live,
        complicationRootURL: @escaping @MainActor () throws -> URL = { try AppGroupContainer.rootURL() },
        reloadComplicationTimelines: @escaping @MainActor () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationSnapshot.widgetKind)
        }
    ) {
        self.storageActor = storageActor
        self.diagnosticsCollector = diagnosticsCollector
        self.clock = clock
        self.diagnosticsPublicationCache = WatchDiagnosticsPublicationCache(
            envelopeData: WatchRelayDiagnosticsEnvelope.unavailableData(
                generatedAt: clock.now(),
                reason: WatchRelayDiagnosticsEnvelopeReason.absent
            )
        )
        self.signposter = signposter
        self.complicationRootURL = complicationRootURL
        self.reloadComplicationTimelines = reloadComplicationTimelines
        let engine = WatchCaptureEngine(
            audioRecorder: LiveWatchAudioRecorder(),
            audioSession: LiveWatchAudioSessionController(),
            locationProvider: LiveWatchLocationProvider(),
            paths: paths,
            storageActor: storageActor,
            clock: clock,
            notificationScheduler: notificationScheduler,
            environmentProvider: environmentProvider,
            signposter: signposter
        )
        engine.onPresentationChanged = { [weak self] presentation in
            self?.presentation = presentation
        }
        engine.onRelayDrainRequested = { [weak relaySender] trigger in
            Task { @MainActor in
                await relaySender?.requestDrain(trigger: trigger)
            }
        }
        engine.onPublishStatus = { [weak self, session, signposter] context in
            let diagnosticsGeneration = self?.diagnosticsPublicationGeneration
            self?.diagnosticsPublicationGeneration = nil
            let publication = signposter.begin(.statusPublication)
            var result: RelayResult = .completed
            defer {
                signposter.end(publication, fields: WatchSignpostFields(result: result))
            }
            let primary = signposter.begin(.applicationContextPrimary)
            do {
                try session.updateApplicationContext(context.applicationContext())
                signposter.end(primary, fields: WatchSignpostFields(result: .completed))
                if let diagnosticsGeneration {
                    self?.diagnosticsPublicationCache.markAccepted(
                        envelopeData: context.diagnosticsEnvelope,
                        generation: diagnosticsGeneration
                    )
                }
            } catch {
                signposter.end(primary, fields: WatchSignpostFields(result: .failed))
                if context.diagnosticsEnvelope != nil,
                   let fallbackEnvelope = WatchRelayDiagnosticsCollector.unavailableEnvelopeData(
                    generatedAt: context.asOf,
                    reason: WatchRelayDiagnosticsEnvelopeReason.publicationFailed
                   ) {
                    let fallbackContext = WatchStatusContext(
                        phase: context.phase,
                        sessionID: context.sessionID,
                        startedAt: context.startedAt,
                        asOf: context.asOf,
                        seq: context.seq,
                        queuedCount: context.queuedCount,
                        transferringCount: context.transferringCount,
                        audioTerminalReason: context.audioTerminalReason,
                        audioTerminalDisposition: context.audioTerminalDisposition,
                        diagnosticsEnvelope: fallbackEnvelope
                    )
                    let fallback = signposter.begin(.applicationContextFallback)
                    do {
                        try session.updateApplicationContext(fallbackContext.applicationContext())
                        signposter.end(fallback, fields: WatchSignpostFields(result: .completed))
                        result = .partial
                        return
                    } catch {
                        signposter.end(fallback, fields: WatchSignpostFields(result: .failed))
                        result = .failed
                        watchCaptureModelLog.error("watch status fallback publish failed: \(String(describing: error), privacy: .public)")
                    }
                }
                result = .failed
                watchCaptureModelLog.error("watch status publish failed: \(String(describing: error), privacy: .public)")
            }
        }
        engine.onDiagnosticsEnvelopeRequested = { [weak self] _ in
            guard let self else { return nil }
            let publication = self.diagnosticsPublicationCache.publication
            self.diagnosticsPublicationGeneration = publication.generation
            return publication.envelopeData
        }
        engine.onDiagnosticsRefreshRequested = { [weak self] in
            self?.enqueueDiagnosticsRefresh()
        }
        relaySender.onStateChanged = { [weak self] in
            self?.enqueueRelayStateRefresh()
        }
        self.engine = engine
        engine.reconcileOnLaunch()
        self.presentation = engine.ownerPresentation
        self.enqueueComplicationSnapshotPublication()
    }

    init(initializationError error: any Error) {
        let clock = SystemObserverClock()
        self.storageActor = nil
        self.diagnosticsCollector = nil
        self.clock = clock
        self.diagnosticsPublicationCache = WatchDiagnosticsPublicationCache(
            envelopeData: WatchRelayDiagnosticsEnvelope.unavailableData(
                generatedAt: clock.now(),
                reason: WatchRelayDiagnosticsEnvelopeReason.absent
            )
        )
        self.signposter = WatchSignpost.live
        self.complicationRootURL = { try AppGroupContainer.rootURL() }
        self.reloadComplicationTimelines = {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationSnapshot.widgetKind)
        }
        self.presentation = WatchCaptureOwnerPresentation(
            status: .needsAttention(WatchCaptureFailureMapper.observerError(for: error)),
            queuedCount: 0
        )
        self.enqueueComplicationSnapshotPublication()
    }

    var isRunning: Bool {
        switch self.presentation.status {
        case .enrolling, .active:
            true
        case .needsAttention:
            self.presentation.isSessionRunning
        case .off:
            false
        }
    }

    func start() {
        self.engine?.start()
        if let engine = self.engine {
            self.presentation = engine.ownerPresentation
        }
    }

    func stop() {
        self.engine?.stop()
        if let engine = self.engine {
            self.presentation = engine.ownerPresentation
        }
    }

    func republishStatusOnReconnect() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.engine?.republishCurrentStatus()
            self.enqueueDiagnosticsRefresh()
        }
    }

    func requestDiagnosticsRefresh() async {
        let generation = self.admitDiagnosticsRefresh()
        while self.completedDiagnosticsRefreshGeneration < generation {
            guard let refreshCoordinatorTask = self.refreshCoordinatorTask else {
                self.ensureRefreshCoordinatorRunning()
                continue
            }
            await refreshCoordinatorTask.value
        }
    }

    func settled() async {
        while true {
            await self.engine?.settled()
            if let refreshCoordinatorTask = self.refreshCoordinatorTask {
                await refreshCoordinatorTask.value
                continue
            }
            await self.complicationPublishTail.value
            guard self.refreshCoordinatorTask == nil else { continue }
            return
        }
    }

    private func admitDiagnosticsRefresh() -> UInt64 {
        let request = self.signposter.begin(.diagnosticsRefreshRequest)
        let result: RelayResult
        if self.diagnosticsRefreshRequested {
            result = .mergedFollowUp
        } else if self.diagnosticsRefreshPassActive {
            result = .scheduledFollowUp
        } else {
            result = .becameOwner
        }
        self.diagnosticsRefreshGeneration &+= 1
        self.diagnosticsRefreshRequested = true
        self.signposter.end(
            request,
            fields: WatchSignpostFields(result: result)
        )
        self.ensureRefreshCoordinatorRunning()
        return self.diagnosticsRefreshGeneration
    }

    private func enqueueComplicationSnapshotPublication() {
        let presentation = self.presentation
        let previous = self.complicationPublishTail
        self.complicationPublishTail = Task { @MainActor [weak self] in
            await previous.value
            guard let self else { return }
            await self.publishComplicationSnapshot(presentation)
        }
    }

    private func enqueueRelayStateRefresh() {
        let request = self.signposter.begin(.relayStateRefreshRequest)
        let result: RelayResult
        if self.relayStateRefreshPassActive {
            if self.relayStateRefreshFollowUpRequested {
                result = .mergedFollowUp
            } else {
                self.relayStateRefreshFollowUpRequested = true
                result = .scheduledFollowUp
            }
        } else if self.relayStateRefreshRequested {
            result = .mergedFollowUp
        } else {
            self.relayStateRefreshRequested = true
            result = .becameOwner
        }
        self.signposter.end(request, fields: WatchSignpostFields(result: result))
        self.ensureRefreshCoordinatorRunning()
    }

    private func enqueueDiagnosticsRefresh() {
        _ = self.admitDiagnosticsRefresh()
    }

    private func ensureRefreshCoordinatorRunning() {
        guard self.refreshCoordinatorTask == nil else { return }
        self.refreshCoordinatorTask = Task { @MainActor [weak self] in
            await self?.runRefreshCoordinator()
        }
    }

    private func runRefreshCoordinator() async {
        while true {
            if self.relayStateRefreshRequested {
                self.relayStateRefreshRequested = false
                self.relayStateRefreshPassActive = true
                await self.runRelayStateRefreshPass()
                self.relayStateRefreshPassActive = false
                _ = self.admitDiagnosticsRefresh()
                if self.relayStateRefreshFollowUpRequested {
                    self.relayStateRefreshFollowUpRequested = false
                    self.relayStateRefreshRequested = true
                }
                continue
            }

            if self.diagnosticsRefreshRequested {
                let generation = self.diagnosticsRefreshGeneration
                self.diagnosticsRefreshRequested = false
                self.diagnosticsRefreshPassActive = true
                await self.runDiagnosticsRefreshPass()
                self.diagnosticsRefreshPassActive = false
                self.completedDiagnosticsRefreshGeneration = generation
                continue
            }

            self.refreshCoordinatorTask = nil
            return
        }
    }

    private func runRelayStateRefreshPass() async {
        guard let engine = self.engine else { return }
        await engine.refreshRelayCountsFromDisk()
        self.presentation = engine.ownerPresentation
    }

    private func runDiagnosticsRefreshPass() async {
        guard let diagnosticsCollector else { return }
        let collection = self.signposter.begin(.diagnosticsCollection)
        let asOf = self.clock.now()
        let envelope = await diagnosticsCollector.makeEnvelopeData(asOf: asOf)
            ?? WatchRelayDiagnosticsEnvelope.unavailableData(
                generatedAt: asOf,
                reason: WatchRelayDiagnosticsEnvelopeReason.encodeFailed
            )
        self.signposter.end(
            collection,
            fields: WatchSignpostFields(result: envelope == nil ? .failed : .completed)
        )
        self.diagnosticsPublicationCache.replaceEnvelope(envelope)
        await self.engine?.republishCurrentStatus()
    }

    private func publishComplicationSnapshot(_ presentation: WatchCaptureOwnerPresentation) async {
        let snapshotInterval = self.signposter.begin(.complicationSnapshot)
        var result: RelayResult = .failed
        defer {
            self.signposter.end(snapshotInterval, fields: WatchSignpostFields(result: result))
        }
        do {
            // Reachability only changes link fields, which the complication snapshot does not persist.
            let snapshot = WatchComplicationSnapshot(presentation: presentation, isReachable: true)
            let encoder = JSONEncoder()
            // JSONEncoder does not guarantee object-key order; match sibling Watch encoders.
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            let url = try self.complicationRootURL()
                .appendingPathComponent(WatchComplicationSnapshot.fileName, isDirectory: false)
            let storageActor = self.storageActor ?? WatchCaptureStorageActor(
                paths: WatchCaptureStoragePaths(rootURL: url.deletingLastPathComponent()),
                fileWriter: FoundationWatchFileWriter()
            )
            self.storageActor = storageActor
            let outcome = try await storageActor.writeComplicationSnapshot(
                data,
                to: url,
                forceWrite: self.complicationRewriteOwed
            )
            switch outcome {
            case .written:
                self.reloadComplicationTimelines()
                self.complicationRewriteOwed = false
                self.recoveryReloadOwed = false
                result = .completed
            case .unchanged where self.recoveryReloadOwed:
                self.reloadComplicationTimelines()
                self.recoveryReloadOwed = false
                result = .recoveryReloaded
            case .unchanged:
                result = .cached
            }
        } catch {
            self.complicationRewriteOwed = true
            watchCaptureModelLog.error("watch complication snapshot publish failed: \(String(describing: error), privacy: .public)")
        }
    }
}
