// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let watchLog = Logger(subsystem: "app.solstone.swift", category: "watch")

@MainActor
@Observable
final class WatchLink {
    private(set) var isReachable: Bool

    @ObservationIgnored private let session: any WatchConnectivitySession

    init(session: any WatchConnectivitySession = LiveWatchConnectivitySession()) {
        self.session = session
        self.isReachable = session.isReachable
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
    }

    func activate() {
        guard self.session.isSupported else {
            watchLog.info("watch: connectivity unavailable")
            self.isReachable = false
            return
        }
        watchLog.info("watch: activating")
        self.session.activate()
    }
}

private extension WatchLink {
    func handleActivationChanged(_ didActivate: Bool) {
        let detail = didActivate ? "completed" : "failed"
        watchLog.info("watch: activation \(detail, privacy: .public)")
        self.isReachable = self.session.isReachable
    }

    func handleReachabilityChanged(_ isReachable: Bool) {
        self.isReachable = isReachable
        let detail = isReachable ? "reachable" : "not reachable"
        watchLog.info("watch: reachability \(detail, privacy: .public)")
    }
}
