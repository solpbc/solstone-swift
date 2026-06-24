// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import WatchConnectivity

private let watchLog = Logger(subsystem: "app.solstone.swift", category: "watch")

@MainActor
@Observable
final class WatchLink {
    private(set) var isSupported: Bool
    private(set) var isReachable: Bool
    private(set) var isPaired: Bool
    private(set) var isWatchAppInstalled: Bool
    private(set) var activationState: WCSessionActivationState

    @ObservationIgnored private let session: any WatchConnectivitySession
    @ObservationIgnored private let receiver: WatchRelayReceiver?

    init(session: any WatchConnectivitySession, receiver: WatchRelayReceiver?) {
        self.session = session
        self.receiver = receiver
        self.isSupported = session.isSupported
        self.isReachable = session.isReachable
        self.isPaired = session.isPaired
        self.isWatchAppInstalled = session.isWatchAppInstalled
        self.activationState = session.activationState
        self.session.onActivationChanged = { [weak self] didActivate in
            Task { @MainActor [weak self] in
                self?.handleActivationChanged(didActivate)
            }
        }
        self.session.onReachabilityChanged = { [weak self] isReachable in
            Task { @MainActor [weak self] in
                self?.handleReachabilityChanged(isReachable)
            }
        }
        self.session.onWatchStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshWatchState()
            }
        }
    }

    func activate() {
        guard self.session.isSupported else {
            watchLog.info("watch: connectivity unavailable")
            self.refreshWatchState()
            return
        }
        watchLog.info("watch: activating")
        self.session.activate()
        self.refreshWatchState()
    }
}

private extension WatchLink {
    func refreshWatchState() {
        self.isSupported = self.session.isSupported
        self.isReachable = self.session.isReachable
        self.isPaired = self.session.isPaired
        self.isWatchAppInstalled = self.session.isWatchAppInstalled
        self.activationState = self.session.activationState
    }

    func handleActivationChanged(_ didActivate: Bool) {
        let detail = didActivate ? "completed" : "failed"
        watchLog.info("watch: activation \(detail, privacy: .public)")
        self.refreshWatchState()
    }

    func handleReachabilityChanged(_ isReachable: Bool) {
        self.isReachable = isReachable
        let detail = isReachable ? "reachable" : "not reachable"
        watchLog.info("watch: reachability \(detail, privacy: .public)")
    }
}
