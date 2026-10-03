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
    private var freshWatchDiagnosticsPayload: WatchRelayDiagnosticsPayload?
    private var hasFreshEligibleDiagnostics = false
    private var hasActiveEligibleActivation = false

    @ObservationIgnored private let session: any WatchConnectivitySession
    @ObservationIgnored private let receiver: WatchRelayReceiver?
    @ObservationIgnored private let facts: WatchSourceFacts
    @ObservationIgnored private let phoneSessionHistoryStore: WatchPhoneSessionHistoryStore
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var lastRelayStuck = false
    @ObservationIgnored private var lastHandoffStuck = false
    @ObservationIgnored private var lastOrphanStuck = false
    @ObservationIgnored var journalVersionProvider: (@MainActor () -> (
        identity: String?, version: String?, current: Bool, versionObservedAt: TimeInterval?,
        journalOS: String?, journalOSVersion: String?, journalArch: String?, journalBuild: String?
    ))?
    @ObservationIgnored private var journalVersionNonce: String?

    var aboutWatchFacts: WatchAboutFacts? {
        guard self.isPaired, self.isWatchAppInstalled,
              self.activationState == .activated,
              self.hasActiveEligibleActivation,
              self.hasFreshEligibleDiagnostics,
              let payload = self.freshWatchDiagnosticsPayload else { return nil }
        return WatchAboutFacts(
            marketingVersion: payload.watchAppMarketingVersion.value,
            build: payload.watchAppBuild.value,
            osVersion: payload.watchOSVersion.value
        )
    }

    func publishJournalVersion() {
        guard session.activationState == .activated,
              let values = journalVersionProvider?() else { return }
        let defaults = UserDefaults.standard
        let revision = defaults.integer(forKey: "sentJournalVersionRevision") + 1
        defaults.set(revision, forKey: "sentJournalVersionRevision")
        let payload = WatchJournalVersionPayload(
            revision: revision,
            identity: values.identity,
            version: values.version,
            current: values.current,
            nonce: journalVersionNonce,
            versionObservedAt: values.versionObservedAt,
            journalOS: values.journalOS,
            journalOSVersion: values.journalOSVersion,
            journalArch: values.journalArch,
            journalBuild: values.journalBuild
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let context: [String: Any] = [WatchJournalVersionPayload.contextKey: data]
        do { try session.updateApplicationContext(context) }
        catch { watchLog.debug("journal version context unavailable") }
        if session.isReachable { session.sendMessage(context) }
    }

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
        self.freshWatchDiagnosticsPayload = nil
        self.hasFreshEligibleDiagnostics = false
        self.hasActiveEligibleActivation = session.activationState == .activated
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
        let previousUserInfo = self.session.onReceiveUserInfo
        self.session.onReceiveUserInfo = { [weak self] info in
            if let nonce = info[WatchJournalVersionPayload.requestKey] as? String {
                self?.journalVersionNonce = nonce
                self?.publishJournalVersion()
            } else {
                previousUserInfo?(info)
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
        let oldPaired = self.isPaired
        let oldInstalled = self.isWatchAppInstalled
        let oldActivationState = self.activationState
        self.isSupported = self.session.isSupported
        self.isReachable = self.session.isReachable
        self.isPaired = self.session.isPaired
        self.isWatchAppInstalled = self.session.isWatchAppInstalled
        self.activationState = self.session.activationState
        if self.activationState == .activated {
            self.activationFailed = false
        }
        if oldPaired != self.isPaired || oldInstalled != self.isWatchAppInstalled
            || oldActivationState != self.activationState || self.activationState != .activated {
            self.clearFreshWatchDiagnostics()
        }
        if self.activationState != .activated {
            self.hasActiveEligibleActivation = false
        } else if oldActivationState != .activated {
            self.hasActiveEligibleActivation = true
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
        if let envelopeData = status?.diagnosticsEnvelope {
            let diagnostics = WatchRelayDiagnosticsEnvelope.decodeResult(from: envelopeData)
            if self.isPaired, self.isWatchAppInstalled, self.activationState == .activated,
               self.hasActiveEligibleActivation,
               let payload = diagnostics.payload {
                self.freshWatchDiagnosticsPayload = payload
                self.hasFreshEligibleDiagnostics = true
            }
            if diagnostics.payload != nil || self.watchDiagnosticsEnvelopeResult.payload == nil {
                self.watchDiagnosticsEnvelopeResult = diagnostics
            }
        }
        _ = self.phoneSessionHistoryStore.merge(diagnostics: self.watchDiagnosticsEnvelopeResult, status: status)
    }

    func handleActivationChanged(_ didActivate: Bool) {
        let detail = didActivate ? "completed" : "failed"
        watchLog.info("watch: activation \(detail, privacy: .public)")
        self.activationFailed = !didActivate
        if !didActivate {
            self.hasActiveEligibleActivation = false
            self.clearFreshWatchDiagnostics()
        }
        self.refreshWatchState()
        if didActivate, self.activationState == .activated {
            self.hasActiveEligibleActivation = true
            self.clearFreshWatchDiagnostics()
        }
        if didActivate { self.publishJournalVersion() }
    }

    func clearFreshWatchDiagnostics() {
        self.hasFreshEligibleDiagnostics = false
        self.freshWatchDiagnosticsPayload = nil
    }

    func handleReachabilityChanged(_ isReachable: Bool) {
        self.isReachable = isReachable
        if !isReachable { self.journalVersionNonce = nil }
        self.publishJournalVersion()
        let detail = isReachable ? "reachable" : "not reachable"
        watchLog.info("watch: reachability \(detail, privacy: .public)")
    }
}
