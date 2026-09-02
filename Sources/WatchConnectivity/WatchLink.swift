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
    private(set) var activationFailed: Bool
    private(set) var watchStatus: WatchStatusContext?
    private(set) var watchDiagnosticsEnvelopeResult: WatchRelayDiagnosticsEnvelopeResult = .absent

    @ObservationIgnored private let session: any WatchConnectivitySession
    @ObservationIgnored private let receiver: WatchRelayReceiver?
    @ObservationIgnored private let facts: WatchSourceFacts
    @ObservationIgnored private let phoneSessionHistoryStore: WatchPhoneSessionHistoryStore
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var lastRelayStuck = false
    @ObservationIgnored private var lastHandoffStuck = false
    @ObservationIgnored private var lastOrphanStuck = false

    var lastReceivedAt: Date? {
        self.receiver?.lastReceivedAt
    }

    var iPhoneACKQueueSnapshot: WatchRelayACKQueueSnapshot {
        WatchRelayACKQueueSnapshot(userInfoTransfers: self.session.outstandingUserInfoTransferSnapshots)
    }

    init(
        session: any WatchConnectivitySession,
        receiver: WatchRelayReceiver?,
        facts: WatchSourceFacts,
        phoneSessionHistoryStore: WatchPhoneSessionHistoryStore,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.session = session
        self.receiver = receiver
        self.facts = facts
        self.phoneSessionHistoryStore = phoneSessionHistoryStore
        self.diagnosticLog = diagnosticLog
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

    func noteStuck(_ input: WatchPipelineInput) {
        let relayStuck = WatchPipelineReducer.isRelayStuck(input)
        let handoffStuck = WatchPipelineReducer.isHandoffStuck(input)
        let orphanStuck = WatchPipelineReducer.isOrphanStuck(input)

        if relayStuck, !self.lastRelayStuck {
            self.diagnosticLog?.append(
                category: .upload,
                severity: .warning,
                message: "needs attention",
                detail: "kind=relay"
            )
        }
        if handoffStuck, !self.lastHandoffStuck {
            self.diagnosticLog?.append(
                category: .upload,
                severity: .warning,
                message: "needs attention",
                detail: "kind=handoff"
            )
        }
        if orphanStuck, !self.lastOrphanStuck {
            self.diagnosticLog?.append(
                category: .upload,
                severity: .warning,
                message: "needs attention",
                detail: "kind=orphan"
            )
        }

        self.lastRelayStuck = relayStuck
        self.lastHandoffStuck = handoffStuck
        self.lastOrphanStuck = orphanStuck
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
        let diagnostics = WatchRelayDiagnosticsEnvelope.decodeResult(
            from: status?.diagnosticsEnvelope
        )
        self.watchDiagnosticsEnvelopeResult = diagnostics
        _ = self.phoneSessionHistoryStore.merge(diagnostics: diagnostics, status: status)
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
