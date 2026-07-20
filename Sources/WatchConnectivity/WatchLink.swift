// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import WatchConnectivity

private let watchLog = Logger(subsystem: "app.solstone.swift", category: "watch")

nonisolated struct WatchRelayACKQueueSnapshot: Equatable, Sendable {
    let total: Int
    let recognizedACK: Int
    let parseableACK: Int
    let distinctIdentities: Int
    let duplicateExtras: Int
    let malformedOrMissing: Int
    let nonACK: Int
    let identityCounts: [UUID: Int]

    init(userInfoTransfers: [WatchConnectivityUserInfoTransferSnapshot] = []) {
        var recognizedACK = 0
        var parseableACK = 0
        var malformedOrMissing = 0
        var nonACK = 0
        var identityCounts: [UUID: Int] = [:]

        for transfer in userInfoTransfers {
            guard transfer.recognizedType == .watchSegmentACK else {
                nonACK += 1
                continue
            }

            recognizedACK += 1
            guard transfer.idState == .parseable, let segmentID = transfer.segmentID else {
                malformedOrMissing += 1
                continue
            }

            parseableACK += 1
            identityCounts[segmentID, default: 0] += 1
        }

        let duplicateExtras = identityCounts.values.reduce(0) { total, count in
            total + max(0, count - 1)
        }

        self.total = userInfoTransfers.count
        self.recognizedACK = recognizedACK
        self.parseableACK = parseableACK
        self.distinctIdentities = identityCounts.keys.count
        self.duplicateExtras = duplicateExtras
        self.malformedOrMissing = malformedOrMissing
        self.nonACK = nonACK
        self.identityCounts = identityCounts
        assert(self.hasConsistentCounts)
    }

    var hasConsistentCounts: Bool {
        self.total >= 0
            && self.recognizedACK >= 0
            && self.parseableACK >= 0
            && self.distinctIdentities >= 0
            && self.duplicateExtras >= 0
            && self.malformedOrMissing >= 0
            && self.nonACK >= 0
            && self.total == self.recognizedACK + self.nonACK
            && self.recognizedACK == self.parseableACK + self.malformedOrMissing
            && self.parseableACK == self.distinctIdentities + self.duplicateExtras
            && self.distinctIdentities == self.identityCounts.keys.count
            && self.duplicateExtras == self.identityCounts.values.reduce(0) { $0 + max(0, $1 - 1) }
    }
}

@MainActor
@Observable
final class WatchLink {
    private(set) var isSupported: Bool
    private(set) var isReachable: Bool
    private(set) var isPaired: Bool
    private(set) var isWatchAppInstalled: Bool
    private(set) var activationState: WCSessionActivationState
    private(set) var activationFailed: Bool
    private(set) var watchStatus: WatchStatusContext?
    private(set) var watchDiagnosticsEnvelopeResult: WatchRelayDiagnosticsEnvelopeResult = .absent

    @ObservationIgnored private let session: any WatchConnectivitySession
    @ObservationIgnored private let receiver: WatchRelayReceiver?
    @ObservationIgnored private let facts: WatchSourceFacts

    var lastReceivedAt: Date? {
        self.receiver?.lastReceivedAt
    }

    var iPhoneACKQueueSnapshot: WatchRelayACKQueueSnapshot {
        WatchRelayACKQueueSnapshot(userInfoTransfers: self.session.outstandingUserInfoTransferSnapshots)
    }

    init(session: any WatchConnectivitySession, receiver: WatchRelayReceiver?, facts: WatchSourceFacts) {
        self.session = session
        self.receiver = receiver
        self.facts = facts
        self.isSupported = session.isSupported
        self.isReachable = session.isReachable
        self.isPaired = session.isPaired
        self.isWatchAppInstalled = session.isWatchAppInstalled
        self.activationState = session.activationState
        self.activationFailed = false
        self.watchStatus = nil
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
        self.session.onReceiveApplicationContext = { [weak self] applicationContext in
            Task { @MainActor [weak self] in
                self?.applyWatchStatus(WatchStatusContext(applicationContext: applicationContext))
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
        self.refreshWatchStatus()
    }
}

private extension WatchLink {
    func refreshWatchState() {
        self.isSupported = self.session.isSupported
        self.isReachable = self.session.isReachable
        self.isPaired = self.session.isPaired
        self.isWatchAppInstalled = self.session.isWatchAppInstalled
        self.activationState = self.session.activationState
        if self.activationState == .activated {
            self.activationFailed = false
        }
    }

    func refreshWatchStatus() {
        self.applyWatchStatus(WatchStatusContext(applicationContext: self.session.receivedApplicationContext))
    }

    func applyWatchStatus(_ status: WatchStatusContext?) {
        self.watchStatus = status
        if status != nil {
            self.facts.noteStatusContextCheckedIn()
        }
        self.watchDiagnosticsEnvelopeResult = WatchRelayDiagnosticsEnvelope.decodeResult(
            from: status?.diagnosticsEnvelope
        )
    }

    func handleActivationChanged(_ didActivate: Bool) {
        let detail = didActivate ? "completed" : "failed"
        watchLog.info("watch: activation \(detail, privacy: .public)")
        self.activationFailed = !didActivate
        self.refreshWatchState()
    }

    func handleReachabilityChanged(_ isReachable: Bool) {
        self.isReachable = isReachable
        let detail = isReachable ? "reachable" : "not reachable"
        watchLog.info("watch: reachability \(detail, privacy: .public)")
    }
}
