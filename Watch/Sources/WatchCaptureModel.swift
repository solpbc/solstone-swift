// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class WatchCaptureModel {
    var presentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0)

    @ObservationIgnored private var engine: WatchCaptureEngine?

    init(storage: WatchCaptureStorage, relaySender: WatchRelaySender) {
        let engine = WatchCaptureEngine(
            audioRecorder: LiveWatchAudioRecorder(),
            audioSession: LiveWatchAudioSessionController(),
            locationProvider: LiveWatchLocationProvider(),
            storage: storage,
            audioProbe: LiveWatchAudioProbe()
        )
        engine.onPresentationChanged = { [weak self] presentation in
            self?.presentation = presentation
        }
        engine.onRelayDrainRequested = { [weak relaySender] in
            relaySender?.drain()
        }
        relaySender.onStateChanged = { [weak self, weak engine] in
            engine?.refreshRelayCountsFromDisk()
            if let engine {
                self?.presentation = engine.ownerPresentation
            }
        }
        self.engine = engine
        Task { @MainActor [weak self, engine] in
            await engine.reconcileOnLaunch()
            self?.presentation = engine.ownerPresentation
        }
    }

    init(initializationError error: any Error) {
        self.presentation = WatchCaptureOwnerPresentation(
            status: .needsAttention(WatchCaptureFailureMapper.observerError(for: error)),
            queuedCount: 0
        )
    }

    var isRunning: Bool {
        switch self.presentation.status {
        case .enrolling, .active, .paused:
            true
        case .needsAttention:
            self.presentation.isSessionRunning
        case .off:
            false
        }
    }

    var primaryText: String {
        self.presentation.headline
    }

    var detailText: String {
        self.presentation.countsLine ?? watchTrustLine()
    }

    var actionText: String {
        self.isRunning ? "stop" : "start"
    }

    func start() {
        Task { @MainActor [weak self] in
            await self?.engine?.start()
            if let engine = self?.engine {
                self?.presentation = engine.ownerPresentation
            }
        }
    }

    func stop() {
        Task { @MainActor [weak self] in
            await self?.engine?.stop()
            if let engine = self?.engine {
                self?.presentation = engine.ownerPresentation
            }
        }
    }
}
