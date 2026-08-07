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
            self.publishComplicationSnapshot()
        }
    }

    @ObservationIgnored private var engine: WatchCaptureEngine?
    @ObservationIgnored private let diagnosticsCollector: WatchRelayDiagnosticsCollector?

    init(
        storage: WatchCaptureStorage,
        relaySender: WatchRelaySender,
        session: any WatchConnectivitySession,
        diagnosticsCollector: WatchRelayDiagnosticsCollector,
        notificationScheduler: any WatchNotificationScheduling,
        environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding
    ) {
        self.diagnosticsCollector = diagnosticsCollector
        let engine = WatchCaptureEngine(
            audioRecorder: LiveWatchAudioRecorder(),
            audioSession: LiveWatchAudioSessionController(),
            locationProvider: LiveWatchLocationProvider(),
            storage: storage,
            audioProbe: LiveWatchAudioProbe(),
            notificationScheduler: notificationScheduler,
            environmentProvider: environmentProvider
        )
        engine.onPresentationChanged = { [weak self] presentation in
            self?.presentation = presentation
        }
        engine.onRelayDrainRequested = { [weak relaySender] in
            relaySender?.drain()
        }
        engine.onPublishStatus = { [session] context in
            do {
                try session.updateApplicationContext(context.applicationContext())
            } catch {
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
                    do {
                        try session.updateApplicationContext(fallbackContext.applicationContext())
                        return
                    } catch {
                        watchCaptureModelLog.error("watch status fallback publish failed: \(String(describing: error), privacy: .public)")
                    }
                }
                watchCaptureModelLog.error("watch status publish failed: \(String(describing: error), privacy: .public)")
            }
        }
        engine.onDiagnosticsEnvelopeRequested = { [diagnosticsCollector] asOf in
            diagnosticsCollector.makeEnvelopeData(asOf: asOf)
        }
        relaySender.onStateChanged = { [weak self, weak engine] in
            engine?.refreshRelayCountsFromDisk()
            if let engine {
                self?.presentation = engine.ownerPresentation
            }
        }
        self.engine = engine
        engine.reconcileOnLaunch()
        self.presentation = engine.ownerPresentation
        self.publishComplicationSnapshot()
    }

    init(initializationError error: any Error) {
        self.diagnosticsCollector = nil
        self.presentation = WatchCaptureOwnerPresentation(
            status: .needsAttention(WatchCaptureFailureMapper.observerError(for: error)),
            queuedCount: 0
        )
        self.publishComplicationSnapshot()
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

    func republishStatusOnReconnect() { self.engine?.republishCurrentStatus() }

    private func publishComplicationSnapshot() {
        do {
            // Reachability only changes link fields, which the complication snapshot does not persist.
            let snapshot = WatchComplicationSnapshot(presentation: self.presentation, isReachable: true)
            let data = try JSONEncoder().encode(snapshot)
            let url = try AppGroupContainer.rootURL()
                .appendingPathComponent(WatchComplicationSnapshot.fileName, isDirectory: false)
            try data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationSnapshot.widgetKind)
        } catch {
            watchCaptureModelLog.error("watch complication snapshot publish failed: \(String(describing: error), privacy: .public)")
        }
    }
}
