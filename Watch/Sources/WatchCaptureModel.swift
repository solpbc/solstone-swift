// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import WidgetKit

private let watchCaptureModelLog = Logger(subsystem: "app.solstone.swift", category: "watch-capture")

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
    @ObservationIgnored private var complicationPublishTail: Task<Void, Never> = Task {}
    @ObservationIgnored private var relayStateRefreshTail: Task<Void, Never> = Task {}

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
        engine.onPublishStatus = { [session, signposter] context in
            let publication = signposter.begin(.statusPublication)
            var result: RelayResult = .completed
            defer {
                signposter.end(publication, fields: WatchSignpostFields(result: result))
            }
            let primary = signposter.begin(.applicationContextPrimary)
            do {
                try session.updateApplicationContext(context.applicationContext())
                signposter.end(primary, fields: WatchSignpostFields(result: .completed))
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
        engine.onDiagnosticsEnvelopeRequested = { [diagnosticsCollector] asOf in
            await diagnosticsCollector.makeEnvelopeData(asOf: asOf)
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
        self.storageActor = nil
        self.diagnosticsCollector = nil
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
            await self?.engine?.republishCurrentStatus()
        }
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
        let previous = self.relayStateRefreshTail
        self.relayStateRefreshTail = Task { @MainActor [weak self] in
            await previous.value
            guard let self, let engine = self.engine else { return }
            await engine.refreshRelayCountsFromDisk()
            self.presentation = engine.ownerPresentation
        }
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
            try await storageActor.writeComplicationSnapshot(data, to: url)
            self.reloadComplicationTimelines()
            result = .completed
        } catch {
            watchCaptureModelLog.error("watch complication snapshot publish failed: \(String(describing: error), privacy: .public)")
        }
    }
}
