// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import WatchConnectivity
import os

private let watchAppLog = Logger(subsystem: "app.solstone.swift", category: "watch-app")

@MainActor
@Observable
final class WatchSessionModel {
    var isReachable = false

    @ObservationIgnored private let session: WCSession?
    @ObservationIgnored private let delegate: WatchSessionDelegate?

    init() {
        guard WCSession.isSupported() else {
            self.session = nil
            self.delegate = nil
            watchAppLog.info("watch app: connectivity unavailable")
            return
        }

        let session = WCSession.default
        let delegate = WatchSessionDelegate()
        self.session = session
        self.delegate = delegate
        delegate.onActivationChanged = { [weak self] didActivate in
            Task { @MainActor [weak self] in
                self?.handleActivationChanged(didActivate)
            }
        }
        delegate.onReachabilityChanged = { [weak self] isReachable in
            Task { @MainActor [weak self] in
                self?.handleReachabilityChanged(isReachable)
            }
        }
    }

    func activate() {
        guard let session, let delegate else {
            self.isReachable = false
            return
        }
        session.delegate = delegate
        self.isReachable = session.isReachable
        watchAppLog.info("watch app: activating")
        session.activate()
    }
}

private extension WatchSessionModel {
    func handleActivationChanged(_ didActivate: Bool) {
        self.isReachable = self.session?.isReachable ?? false
        let detail = didActivate ? "completed" : "failed"
        watchAppLog.info("watch app: activation \(detail, privacy: .public)")
    }

    func handleReachabilityChanged(_ isReachable: Bool) {
        self.isReachable = isReachable
        let detail = isReachable ? "reachable" : "not reachable"
        watchAppLog.info("watch app: reachability \(detail, privacy: .public)")
    }
}
