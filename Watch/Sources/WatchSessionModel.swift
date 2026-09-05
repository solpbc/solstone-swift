// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let watchAppLog = Logger(subsystem: "app.solstone.swift", category: "watch-app")

@MainActor
@Observable
final class WatchSessionModel {
    let journalVersion = WatchJournalVersionState()
    var isReachable = false {
        didSet { if !isReachable { journalVersion.disconnected() } }
    }

    @ObservationIgnored var onReachableRepublish: (@MainActor () -> Void)?
    @ObservationIgnored private let session: any WatchConnectivitySession
    @ObservationIgnored private let relaySender: WatchRelaySender?

    init(session: any WatchConnectivitySession, relaySender: WatchRelaySender?) {
        self.session = session
        self.relaySender = relaySender
        self.isReachable = session.isReachable
        self.session.onReceiveApplicationContext = { [weak self] context in
            if let data = context[WatchJournalVersionPayload.contextKey] as? Data {
                self?.journalVersion.receive(data, live: false)
            }
        }
        let previousUserInfo = self.session.onReceiveUserInfo
        self.session.onReceiveUserInfo = { [weak self] info in
            if let data = info[WatchJournalVersionPayload.contextKey] as? Data {
                self?.journalVersion.receive(data, live: self?.isReachable == true)
            } else {
                previousUserInfo?(info)
            }
        }
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
    func requestJournalVersion() {
        guard isReachable else { return }
        let nonce = journalVersion.beginReachableSession()
        session.sendMessage([WatchJournalVersionPayload.requestKey: nonce])
    }

    func handleActivationChanged(_ didActivate: Bool) {
        self.isReachable = self.session.isReachable
        let detail = didActivate ? "completed" : "failed"
        watchAppLog.info("watch app: activation \(detail, privacy: .public)")
        if didActivate {
            if let data = session.receivedApplicationContext[WatchJournalVersionPayload.contextKey] as? Data {
                journalVersion.receive(data, live: false)
            }
            requestJournalVersion()
            Task { @MainActor in
                await self.relaySender?.requestDrain(trigger: .connectivityActivation)
            }
            self.onReachableRepublish?()
        }
    }

    func handleReachabilityChanged(_ isReachable: Bool) {
        self.isReachable = isReachable
        let detail = isReachable ? "reachable" : "not reachable"
        watchAppLog.info("watch app: reachability \(detail, privacy: .public)")
        if isReachable {
            requestJournalVersion()
            Task { @MainActor in
                await self.relaySender?.requestDrain(trigger: .connectivityReachability)
            }
            self.onReachableRepublish?()
        }
    }
}
