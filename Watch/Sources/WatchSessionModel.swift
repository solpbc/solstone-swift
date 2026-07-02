// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let watchAppLog = Logger(subsystem: "app.solstone.swift", category: "watch-app")

@MainActor
@Observable
final class WatchSessionModel {
    var isReachable = false

    @ObservationIgnored var onReachableRepublish: (@MainActor () -> Void)?
    @ObservationIgnored private let session: any WatchConnectivitySession
    @ObservationIgnored private let relaySender: WatchRelaySender?

    init(session: any WatchConnectivitySession, relaySender: WatchRelaySender?) {
        self.session = session
        self.relaySender = relaySender
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
            self.isReachable = false
            watchAppLog.info("watch app: connectivity unavailable")
            return
        }
        self.isReachable = self.session.isReachable
        watchAppLog.info("watch app: activating")
        self.session.activate()
    }
}

private extension WatchSessionModel {
    func handleActivationChanged(_ didActivate: Bool) {
        self.isReachable = self.session.isReachable
        let detail = didActivate ? "completed" : "failed"
        watchAppLog.info("watch app: activation \(detail, privacy: .public)")
        if didActivate {
            self.relaySender?.drain()
            self.onReachableRepublish?()
        }
    }

    func handleReachabilityChanged(_ isReachable: Bool) {
        self.isReachable = isReachable
        let detail = isReachable ? "reachable" : "not reachable"
        watchAppLog.info("watch app: reachability \(detail, privacy: .public)")
        if isReachable {
            self.relaySender?.drain()
            self.onReachableRepublish?()
        }
    }
}
