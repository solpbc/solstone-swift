// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

private let watchCaptureLog = Logger(subsystem: "app.solstone.swift", category: "watch-capture")

typealias WatchAudioSessionNotificationHandoff =
    @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

@MainActor
final class WatchCaptureEngine {
    private enum LifecycleState: Equatable, Sendable {
        case idle
        case reconciling
        case starting
        case running(sessionID: String)
        case stopping(sessionID: String)
    }

    private struct ReconcileReadinessSeed: Sendable {
        let reconciledSessionID: String?
        let deferredTerminalNotice: WatchCaptureTerminalTuple?
    }

    private struct RelayCounts: Equatable, Sendable {
        let queued: Int
        let transferring: Int
        let confirming: Int
        let handedOff: Int
    }

    var onPresentationChanged: (@Sendable @MainActor (WatchCaptureOwnerPresentation) -> Void)?
    var onRelayDrainRequested: (@MainActor (RelayTrigger) -> Void)?
    var onPublishStatus: (@MainActor (WatchStatusContext) -> Void)?
    var onDiagnosticsEnvelopeRequested: (@MainActor (Date) async -> Data?)?

    private let audioRecorder: any WatchAudioRecording
    private let audioSession: any WatchAudioSessionControlling
    private let locationProvider: any WatchLocationProviding
    private let paths: WatchCaptureStoragePaths
    private let storageActor: WatchCaptureStorageActor
    private let clock: any ObserverClock
    private let notificationScheduler: any WatchNotificationScheduling
    private let notificationCenter: NotificationCenter
    private let audioSessionNotificationHandoff: WatchAudioSessionNotificationHandoff
    private let environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding
    private let signposter: any WatchSignposting
    let lifecycleSerializer: WatchCaptureLifecycleSerializer

    private var activeSegment: ActiveSegment?
    private var openingSegment: ActiveSegment?
    /// The first manifest made it to disk. Its media must remain recoverable if
    /// opening the fully-persisted successor later fails.
    private var openingSegmentHasPersistedManifest = false
    private var rolloverPriorSegment: ActiveSegment?
    private var rolloverPriorAudioDuration: TimeInterval?
    private var segmentationTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var locationFixTail: Task<Void, Never> = Task { @MainActor in }
    /// Closed before a segment leaves `activeSegment`, so callbacks admitted
    /// while finalization waits for the existing tail cannot target that segment.
    private var locationFixDeliveryClosed = false
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var audioSessionIsActive = false
    private var audioArmed = false
    private var locationArmed = false
    private var lastKnownFix: WatchLocationFix?
    private var lastAudioCurrentTime: TimeInterval?
    private var status: WatchCaptureRuntimeStatus = .off
    private var statusSeq = 0
    private var currentSessionID: String?
    private var currentAudioEnrollment: UUID?
    private var sessionStartedAt: Date?
    private var startRefusalReason: WatchCaptureStartRefusalReason?
    private var settingsRoute: WatchCaptureSettingsRoute?
    private var terminalReason: WatchCaptureTerminalReason?
    private var terminalDisposition: WatchCaptureTerminalDisposition?
    private var notificationAuthorizationStatus: WatchNotificationAuthorizationStatus?
    private var notificationAlertSetting: WatchNotificationAlertSetting?
    private var wristAlertAssurance: WatchWristAlertAssurance?
    private var leaseIsArmed = false
    private var lastVerifiedAudioAt: Date?
    private var locationAdvisory: WatchCaptureLocationAdvisory?
    private var persistenceAdvisory: WatchCapturePersistenceAdvisory?
    private var queuedCount = 0
    private var transferringCount = 0
    private var confirmingCount = 0
    private var handedOffCount = 0
    private var zeroAudioCurrentTimeObservationCount = 0
    private var terminalEnvironmentSnapshot: WatchRelayDiagnosticsEnvironmentSnapshot?
    private var lifecycleState: LifecycleState = .idle
    private var lifecycleGeneration = 0
    private var presentationAdmissionGeneration = 0
    private var admittedStartPending = false
    private var captureSafetyReadinessFailed = false
    private var maintenanceGeneration = 0
    private var maintenanceTask: Task<Void, Never>?
    private var executingLifecycleIntent: WatchCaptureLifecycleSerializer.Intent?
    private var terminalClaimedSessionIDs: Set<String> = []

    init(
        audioRecorder: any WatchAudioRecording,
        audioSession: any WatchAudioSessionControlling,
        locationProvider: any WatchLocationProviding,
        paths: WatchCaptureStoragePaths,
        storageActor: WatchCaptureStorageActor,
        clock: any ObserverClock = SystemObserverClock(),
        notificationScheduler: any WatchNotificationScheduling,
        environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding = LiveWatchRelayDiagnosticsEnvironmentProvider(),
        notificationCenter: NotificationCenter = .default,
        signposter: any WatchSignposting = WatchSignpost.live,
        audioSessionNotificationHandoff: @escaping WatchAudioSessionNotificationHandoff = { operation in
            Task { @MainActor in operation() }
        }
    ) {
        self.audioRecorder = audioRecorder
        self.audioSession = audioSession
        self.locationProvider = locationProvider
        self.paths = paths
        self.storageActor = storageActor
        self.clock = clock
        self.notificationScheduler = notificationScheduler
        self.environmentProvider = environmentProvider
        self.signposter = signposter
        self.notificationCenter = notificationCenter
        self.audioSessionNotificationHandoff = audioSessionNotificationHandoff
        self.lifecycleSerializer = WatchCaptureLifecycleSerializer()

        self.audioRecorder.eventSink = self
        self.locationProvider.onFix = { [weak self] fix in
            guard let self else { return }
            let segmentID = self.locationFixDeliveryClosed ? nil : self.activeSegment?.manifest.id
            let previous = self.locationFixTail
            self.locationFixTail = Task { @MainActor [weak self] in
                await previous.value
                guard let self else { return }
                await self.handleFix(fix, for: segmentID)
            }
        }
        self.locationProvider.onAuthorizationChanged = { [weak self] authorization in
            self?.handleAuthorizationChanged(authorization)
        }
        self.locationProvider.onFailure = { [weak self] error in
            self?.handleLocationFailure(error)
        }
        self.lifecycleSerializer.configure(
            owner: self,
            admission: { engine, intent in engine.admitLifecycleIntent(intent) },
            executor: { engine, intent in await engine.executeLifecycleIntent(intent) }
        )
    }

    var ownerPresentation: WatchCaptureOwnerPresentation {
        WatchCaptureOwnerPresentation(
            status: self.status,
            queuedCount: self.queuedCount,
            transferringCount: self.transferringCount,
            confirmingCount: self.confirmingCount,
            handedOffCount: self.handedOffCount,
            isSessionRunning: self.activeSegment != nil,
            sessionStartedAt: self.sessionStartedAt,
            settingsRoute: self.settingsRoute,
            startRefusalReason: self.startRefusalReason,
            terminalReason: self.terminalReason,
            terminalDisposition: self.terminalDisposition,
            locationAdvisory: self.locationAdvisory,
            persistenceAdvisory: self.persistenceAdvisory,
            wristAlertAssurance: self.wristAlertAssurance,
            lastVerifiedAudioAt: self.lastVerifiedAudioAt
        )
    }

    func refreshRelayCountsFromDisk() async {
        let priorQueued = self.queuedCount
        let priorTransferring = self.transferringCount
        await self.refreshRelayCountsFromDiskCatalog()
        if self.queuedCount != priorQueued || self.transferringCount != priorTransferring {
            await self.republishCurrentStatus()
        }
        self.notifyPresentationChanged()
    }

    func reconcileOnLaunch() {
        self.lifecycleSerializer.submit(.reconcile)
    }

    func start() {
        self.lifecycleSerializer.submit(.start)
    }

    func stop() {
        self.lifecycleSerializer.submit(.stop)
    }

    func settled() async {
        while true {
            await self.lifecycleSerializer.settled()
            await self.waitForAdmittedLocationFixes()
            if let maintenanceTask = self.maintenanceTask {
                await maintenanceTask.value
                continue
            }
            return
        }
    }

    private func reconcileCaptureSafetyReadiness(generation: Int) async -> ReconcileReadinessSeed? {
        let reconciliation = self.signposter.begin(.reconciliationReadiness)
        var result: RelayResult = .failed
        defer {
            self.signposter.end(reconciliation, fields: WatchSignpostFields(result: result))
        }
        self.terminalReason = nil
        self.terminalDisposition = nil
        guard let sessionReadiness = await self.reconcileSessionRecord(generation: generation) else {
            result = .partial
            return nil
        }
        guard await self.continueLifecycleOperation(generation) else {
            result = .partial
            return nil
        }
        let manifestScan = self.signposter.begin(.manifestScan)
        let catalog = await self.storageActor.scanCatalog(transactionClass: .captureSafety)
        var recoveryFailed = false
        for entry in catalog.entries {
            do {
                switch entry.manifest.state {
                case .captured, .persisted:
                    try await self.recoverUnclean(entry, sessionID: sessionReadiness.reconciledSessionID)
                case .finalized, .queued, .transferring, .delivered, .acked, .safeToDelete:
                    break
                }
            } catch {
                recoveryFailed = true
                watchCaptureLog.error(
                    "watch reconcile recovery failed id=\(entry.manifest.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)"
                )
            }
        }
        self.applyCatalogAdvisory(catalog.rootState)
        self.signposter.end(
            manifestScan,
            fields: WatchSignpostFields(result: recoveryFailed ? .partial : self.catalogResult(catalog.rootState))
        )
        result = recoveryFailed ? .partial : self.catalogResult(catalog.rootState)
        return sessionReadiness
    }

    private func startReconcileMaintenance(seed: ReconcileReadinessSeed) {
        self.maintenanceGeneration &+= 1
        self.maintenanceTask?.cancel()
        let maintenanceGeneration = self.maintenanceGeneration
        let presentationAdmissionGeneration = self.presentationAdmissionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReconcileMaintenance(
                seed: seed,
                maintenanceGeneration: maintenanceGeneration,
                presentationAdmissionGeneration: presentationAdmissionGeneration
            )
        }
        self.maintenanceTask = task
    }

    private func runReconcileMaintenance(
        seed: ReconcileReadinessSeed,
        maintenanceGeneration: Int,
        presentationAdmissionGeneration: Int
    ) async {
        let maintenance = self.signposter.begin(.reconciliationMaintenance)
        var result: RelayResult = .completed
        defer {
            self.signposter.end(maintenance, fields: WatchSignpostFields(result: result))
            if maintenanceGeneration == self.maintenanceGeneration {
                self.maintenanceTask = nil
            }
        }

        if let deferredTerminalNotice = seed.deferredTerminalNotice {
            await self.submitTerminalNotice(expected: deferredTerminalNotice)
        }
        guard !Task.isCancelled else {
            result = .partial
            return
        }

        var maintenanceFailed = false
        let finalizedCatalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
        for entry in finalizedCatalog.entries where entry.manifest.state == .finalized {
            guard !Task.isCancelled else {
                result = .partial
                return
            }
            do {
                var manifest = entry.manifest
                manifest.state = .queued
                try await self.storageActor.writeManifest(manifest, ensuringDirectory: false)
            } catch {
                maintenanceFailed = true
                watchCaptureLog.error(
                    "watch reconcile queue rewrite failed id=\(entry.manifest.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)"
                )
            }
        }

        let relayCountRefresh = self.signposter.begin(.relayCountRefresh)
        let refreshedCatalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
        self.signposter.end(
            relayCountRefresh,
            fields: WatchSignpostFields(result: self.catalogResult(refreshedCatalog.rootState))
        )
        guard !Task.isCancelled else {
            result = .partial
            return
        }

        guard self.isMaintenanceCurrent(
            maintenanceGeneration,
            presentationAdmissionGeneration: presentationAdmissionGeneration
        ) else {
            result = .partial
            self.requestRelayDrain(trigger: .launchReconciliation)
            return
        }
        self.applyRelayCounts(self.relayCounts(from: refreshedCatalog))
        self.applyCatalogAdvisory(refreshedCatalog.rootState)
        await self.republishCurrentStatus()
        self.notifyPresentationChanged()
        self.requestRelayDrain(trigger: .launchReconciliation)
        if maintenanceFailed || Task.isCancelled {
            result = .partial
        }
    }

    private func startInner(generation: Int) async {
        self.clearTransientStateForStart()
        guard await self.mintSessionIdentity(startedAt: self.clock.now()) else {
            self.status = .needsAttention(.unavailable(reason: SourceVocabulary.watchStatusSaveFailed))
            self.notifyPresentationChanged()
            return
        }
        guard await self.continueLifecycleOperation(generation) else { return }
        guard let currentSessionID else { return }
        let ownerSource = WatchCaptureSourceToken(sessionID: currentSessionID)
        guard await self.refreshWristAlertState(
            requestIfNotDetermined: true,
            generation: generation
        ) != nil else { return }

        guard await self.prepareAudioForOwnerStart(generation: generation) else {
            if self.isLifecycleGenerationCurrent(generation) {
                await self.publishStatus(.idle)
                self.notifyPresentationChanged()
            }
            return
        }
        guard await self.continueLifecycleOperation(generation) else { return }

        self.locationArmed = self.armLocation()
        if self.locationArmed {
            do {
                try self.locationProvider.start()
            } catch {
                self.locationArmed = false
                self.locationAdvisory = .providerFailed
                watchCaptureLog.error("watch location start failed: \(String(describing: error), privacy: .public)")
            }
        }

        do {
            let startedAt = self.sessionStartedAt ?? self.clock.now()
            guard await self.beginStatusSession(startedAt: startedAt) else {
                self.status = .needsAttention(.unavailable(reason: SourceVocabulary.watchStatusSaveFailed))
                self.notifyPresentationChanged()
                return
            }
            guard await self.continueLifecycleOperation(generation) else { return }
            guard try await self.openSegment(
                startedAt: startedAt,
                ownerSessionID: currentSessionID,
                generation: generation
            ) else { return }
            guard await self.continueLifecycleOperation(generation) else { return }
            guard let segment = self.activeSegment else { return }
            if !segment.hasLiveSensor {
                await self.refuseInitialStartAfterSegmentOpen(
                    error: .unavailable(reason: SourceVocabulary.watchMicrophoneUnavailable)
                )
                return
            }
            await self.writeActiveSessionRecord(startedAt: startedAt)
            guard await self.continueLifecycleOperation(generation) else { return }
            await self.replaceAudioTruthLease(verifiedAt: startedAt, generation: generation)
            guard await self.continueLifecycleOperation(generation) else { return }
            self.installAudioSessionObservers(source: ownerSource)
            self.status = self.statusForRunningSegment(segment)
            self.startSegmentationTask()
        } catch WatchCaptureEngineError.audioStartFailed {
            guard await self.continueLifecycleOperation(generation) else { return }
            await self.refuseInitialStartAfterSegmentOpen(
                error: WatchCaptureTerminalReason.audioStartFailed.observerError
            )
            return
        } catch {
            guard await self.continueLifecycleOperation(generation) else { return }
            await self.refuseInitialStartAfterSegmentOpen(
                error: WatchCaptureFailureMapper.observerError(for: error),
                persistenceFailed: self.openingSegmentHasPersistedManifest
            )
            return
        }
        if self.activeSegment != nil {
            await self.publishStatus(.observing)
            self.startHeartbeatTask(source: ownerSource)
        } else {
            await self.publishStatus(.idle)
        }
        self.notifyPresentationChanged()
    }

    private func stopInner() async {
        await self.publishStatus(.stopping)
        await self.terminalize(
            reason: .ownerStopped,
            disposition: .ownerStopped,
            at: self.clock.now()
        )
    }

    func republishCurrentStatus() async {
        let phase: WatchStatusContext.Phase = self.activeSegment == nil ? .idle : .observing
        await self.publishStatus(phase)
    }

    private func admitLifecycleIntent(
        _ intent: WatchCaptureLifecycleSerializer.Intent
    ) -> WatchCaptureLifecycleSerializer.AdmissionDecision {
        switch intent {
        case .start:
            switch self.lifecycleState {
            case .idle, .reconciling:
                self.presentationAdmissionGeneration &+= 1
                self.admittedStartPending = true
                self.status = .enrolling
                self.notifyPresentationChanged()
            case .starting, .running, .stopping:
                break
            }
        case .stop:
            if self.executingIntentCanBeSupersededByStop {
                self.lifecycleGeneration &+= 1
            }
            if self.admittedStartPending {
                self.presentationAdmissionGeneration &+= 1
                self.admittedStartPending = false
                self.status = .off
                self.notifyPresentationChanged()
            }
        case .reconcile, .rollover, .terminal:
            break
        }
        return .enqueue
    }

    private func executeLifecycleIntent(_ intent: WatchCaptureLifecycleSerializer.Intent) async {
        self.lifecycleGeneration &+= 1
        let generation = self.lifecycleGeneration
        self.executingLifecycleIntent = intent
        defer { self.executingLifecycleIntent = nil }

        switch intent {
        case .reconcile:
            guard case .idle = self.lifecycleState else { return }
            self.lifecycleState = .reconciling
            let readiness = await self.reconcileCaptureSafetyReadiness(generation: generation)
            guard self.isLifecycleGenerationCurrent(generation) else { return }
            if case .reconciling = self.lifecycleState {
                self.lifecycleState = .idle
            }
            if let readiness {
                self.startReconcileMaintenance(seed: readiness)
            }

        case .start:
            self.admittedStartPending = false
            guard case .idle = self.lifecycleState else { return }
            self.lifecycleState = .starting
            guard !self.captureSafetyReadinessFailed else {
                self.status = .needsAttention(.unavailable(reason: SourceVocabulary.watchStatusSaveFailed))
                self.notifyPresentationChanged()
                self.lifecycleState = .idle
                return
            }
            await self.startInner(generation: generation)
            // A stale start may have completed its synchronous live-resource tail.
            // Converge through terminalization before returning to idle.
            guard self.isLifecycleGenerationCurrent(generation) else {
                _ = await self.continueLifecycleOperation(generation)
                self.lifecycleState = .idle
                return
            }
            if let sessionID = self.currentSessionID, self.activeSegment != nil {
                self.lifecycleState = .running(sessionID: sessionID)
            } else {
                self.lifecycleState = .idle
            }

        case .stop:
            guard case let .running(sessionID) = self.lifecycleState else { return }
            self.lifecycleState = .stopping(sessionID: sessionID)
            await self.stopInner()
            self.lifecycleState = .idle

        case .rollover:
            guard case let .running(sessionID) = self.lifecycleState else { return }
            await self.rolloverInner(generation: generation, ownerSessionID: sessionID)
            // A stale rollover may have opened a successor before its final callback.
            // Converge through terminalization before returning to idle.
            guard self.isLifecycleGenerationCurrent(generation) else {
                _ = await self.continueLifecycleOperation(generation)
                self.lifecycleState = .idle
                return
            }
            if self.activeSegment == nil {
                self.lifecycleState = .idle
            } else {
                self.lifecycleState = .running(sessionID: sessionID)
            }

        case let .terminal(terminal):
            guard case let .running(sessionID) = self.lifecycleState,
                  terminal.source.sessionID == sessionID
            else { return }
            if let enrollment = terminal.source.enrollment,
               enrollment != self.currentAudioEnrollment {
                return
            }
            self.lifecycleState = .stopping(sessionID: sessionID)
            await self.terminalize(
                reason: terminal.reason,
                disposition: terminal.disposition,
                at: self.clock.now(),
                liveness: terminal.livenessEvidence
            )
            self.lifecycleState = .idle
        }

    }

    private var executingIntentCanBeSupersededByStop: Bool {
        guard let executingLifecycleIntent else { return false }
        switch executingLifecycleIntent {
        case .start, .rollover:
            return true
        case .reconcile, .stop, .terminal:
            return false
        }
    }

    private func isLifecycleGenerationCurrent(_ generation: Int) -> Bool {
        self.lifecycleGeneration == generation
    }

    private func isMaintenanceCurrent(
        _ maintenanceGeneration: Int,
        presentationAdmissionGeneration: Int
    ) -> Bool {
        maintenanceGeneration == self.maintenanceGeneration
            && presentationAdmissionGeneration == self.presentationAdmissionGeneration
    }

    /// Once it has a session identity, a stale lifecycle continuation may only
    /// leave through terminalization. This keeps a superseded start from writing
    /// a refusal-shaped history row.
    private func continueLifecycleOperation(_ generation: Int) async -> Bool {
        guard !self.isLifecycleGenerationCurrent(generation) else { return true }
        guard self.currentSessionID != nil else {
            self.status = .off
            await self.publishStatus(.idle)
            self.notifyPresentationChanged()
            return false
        }
        await self.terminalize(
            reason: .ownerStopped,
            disposition: .ownerStopped,
            at: self.clock.now()
        )
        return false
    }
}

private enum WatchCaptureEngineError: Error {
    case audioStartFailed
}

extension WatchCaptureEngine: WatchAudioRecorderEventSink {
    func audioRecorderDidFinish(successfully: Bool, source: WatchCaptureSourceToken) {
        guard !successfully else { return }
        self.submitTerminalIntent(
            reason: .audioFinishUnsuccessful,
            disposition: .detectedStoppedItself,
            source: source
        )
    }

    func audioRecorderEncodeError(_ error: (any Error)?, source: WatchCaptureSourceToken) {
        if let error {
            watchCaptureLog.error("watch audio encode failed: \(String(describing: error), privacy: .public)")
        }
        self.submitTerminalIntent(
            reason: .audioEncodeError,
            disposition: .detectedStoppedItself,
            source: source
        )
    }
}

private extension WatchCaptureEngine {
    func waitForAdmittedLocationFixes() async {
        let tail = self.locationFixTail
        await tail.value
    }

    func performSignposted<Value>(
        _ boundary: WatchSignpostBoundary,
        operation: () throws -> Value
    ) rethrows -> Value {
        let interval = self.signposter.begin(boundary)
        do {
            let value = try operation()
            self.signposter.end(interval, fields: WatchSignpostFields(result: .completed))
            return value
        } catch {
            self.signposter.end(interval, fields: WatchSignpostFields(result: .failed))
            throw error
        }
    }

    func performSignposted<Value>(
        _ boundary: WatchSignpostBoundary,
        operation: () async throws -> Value
    ) async rethrows -> Value {
        let interval = self.signposter.begin(boundary)
        do {
            let value = try await operation()
            self.signposter.end(interval, fields: WatchSignpostFields(result: .completed))
            return value
        } catch {
            self.signposter.end(interval, fields: WatchSignpostFields(result: .failed))
            throw error
        }
    }

    static let heartbeatIntervalSeconds = 15
    static let zeroAudioCurrentTimeObservationLimit = 3

    struct ActiveSegment {
        var directoryURL: URL
        var manifest: WatchSegmentManifest
        var audioURL: URL?
        var locationURL: URL?
        var partialError: ObserverError?
        var hasElapsedLocationCoverage: Bool

        var hasLiveSensor: Bool {
            self.audioURL != nil || self.locationURL != nil
        }
    }

    enum FinalizationDisposition {
        case discard
        case retain
        case queue
    }

    struct PreparedFinalization {
        let segment: ActiveSegment
        let manifest: WatchSegmentManifest
        let verifiedAudioAt: Date?
        let disposition: FinalizationDisposition
    }

    struct DeclaredSensorEvidence {
        let sensors: [WatchSensor]
        let unknownPresence: [WatchSensor]
    }

    func clearTransientStateForStart() {
        self.locationFixDeliveryClosed = false
        self.currentSessionID = nil
        self.currentAudioEnrollment = nil
        self.sessionStartedAt = nil
        self.startRefusalReason = nil
        self.settingsRoute = nil
        self.terminalReason = nil
        self.terminalDisposition = nil
        self.persistenceAdvisory = nil
        self.terminalEnvironmentSnapshot = nil
        self.lastAudioCurrentTime = nil
        self.zeroAudioCurrentTimeObservationCount = 0
    }

    func prepareAudioForOwnerStart(generation: Int) async -> Bool {
        switch self.audioRecorder.microphonePermission {
        case .granted:
            break
        case .denied:
            await self.refuseStart(.microphonePermissionDenied, error: .permissionDenied, settingsRoute: .microphone)
            return false
        case .notDetermined:
            let requested = await self.audioRecorder.requestPermission()
            guard await self.continueLifecycleOperation(generation) else { return false }
            guard requested == .granted else {
                await self.refuseStart(.microphonePermissionNotDetermined, error: .permissionDenied, settingsRoute: .microphone)
                return false
            }
        }
        do {
            try self.audioSession.setCategory(.record, mode: .measurement, options: [])
            try self.audioSession.setActive(true, options: [])
            self.audioSessionIsActive = true
            self.audioArmed = true
            return true
        } catch {
            await self.refuseStart(.audioArmFailed, error: WatchCaptureFailureMapper.observerError(for: error))
            return false
        }
    }

    func refuseStart(
        _ reason: WatchCaptureStartRefusalReason,
        error: ObserverError,
        settingsRoute: WatchCaptureSettingsRoute? = nil
    ) async {
        let sessionID = self.currentSessionID
        let startedAt = self.sessionStartedAt
        self.startRefusalReason = reason
        self.settingsRoute = settingsRoute
        self.status = .needsAttention(error)
        self.currentSessionID = nil
        self.currentAudioEnrollment = nil
        self.sessionStartedAt = nil
        self.audioArmed = false
        if self.locationArmed {
            self.locationProvider.stop()
        }
        self.locationArmed = false
        if self.audioSessionIsActive {
            try? self.audioSession.setActive(false, options: [])
            self.audioSessionIsActive = false
        }
        if let sessionID, let startedAt {
            _ = await self.upsertSessionHistory(
                sessionID: sessionID,
                startedAt: startedAt,
                terminalAt: nil,
                noticeOwed: false,
                liveness: nil,
                environment: nil,
                transactionClass: .captureSafety
            )
        }
    }

    /// Start-time setup never became a live session. Shut down any recorder the
    /// failed open may have touched, retain non-empty owner media, then preserve
    /// the established refusal-shaped lifecycle fact.
    func refuseInitialStartAfterSegmentOpen(
        error: ObserverError,
        persistenceFailed: Bool = false
    ) async {
        let segment = self.activeSegment ?? self.openingSegment
        self.activeSegment = nil
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
        self.currentAudioEnrollment = nil
        if self.audioArmed, segment?.audioURL != nil {
            _ = try? self.audioRecorder.stop()
        }
        if let segment {
            _ = await self.removeSegmentDirectoryIfMediaIsProvablyEmpty(segment.directoryURL)
        }
        self.removeAudioTruthLease()
        if persistenceFailed {
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        await self.refuseStart(.audioArmFailed, error: error)
        await self.publishStatus(.idle)
        self.notifyPresentationChanged()
    }

    func armLocation() -> Bool {
        switch self.locationProvider.authorizationStatus {
        case .authorized:
            return true
        case .notDetermined:
            self.locationProvider.requestWhenInUseAuthorization()
            return false
        case .denied:
            return false
        }
    }

    func openSegment(
        startedAt: Date,
        ownerSessionID: String,
        generation: Int?
    ) async throws -> Bool {
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
        let day = self.paths.dayString(for: startedAt)
        let segmentKey = self.paths.provisionalSegmentString(for: startedAt)
        let directory: URL
        do {
            directory = try await self.storageActor.prepareSegmentDirectory(day: day, segment: segmentKey)
        } catch {
            guard await self.continueOpeningLifecycleOperation(generation) else { return false }
            throw error
        }
        guard await self.continueOpeningLifecycleOperation(
            generation,
            emptyDirectory: directory
        ) else { return false }
        var sensors: [WatchSensor] = []
        if self.audioArmed {
            sensors.append(.audio)
        }
        if self.locationArmed {
            sensors.append(.location)
        }
        var manifest = WatchSegmentManifest(
            id: UUID(),
            day: day,
            segment: segmentKey,
            startedAt: startedAt,
            duration: 0,
            sensors: sensors,
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil
        )
        var active = ActiveSegment(
            directoryURL: directory,
            manifest: manifest,
            audioURL: nil,
            locationURL: nil,
            partialError: nil,
            hasElapsedLocationCoverage: false
        )
        self.openingSegment = active
        do {
            try await self.storageActor.writeManifest(manifest, ensuringDirectory: false)
        } catch {
            guard await self.continueOpeningLifecycleOperation(generation) else { return false }
            throw error
        }
        guard await self.continueOpeningLifecycleOperation(generation) else { return false }
        self.openingSegmentHasPersistedManifest = true

        if self.audioArmed {
            let audioURL = self.paths.audioURL(directory: directory)
            active.audioURL = audioURL
            active.manifest = manifest
            self.openingSegment = active
            do {
                let enrollment = UUID()
                self.currentAudioEnrollment = enrollment
                try self.audioRecorder.start(
                    url: audioURL,
                    source: WatchCaptureSourceToken(sessionID: ownerSessionID, enrollment: enrollment)
                )
                self.lastAudioCurrentTime = self.audioRecorder.currentTime
                self.zeroAudioCurrentTimeObservationCount = 0
            } catch {
                self.currentAudioEnrollment = nil
                watchCaptureLog.error("watch audio start failed: \(String(describing: error), privacy: .public)")
                throw WatchCaptureEngineError.audioStartFailed
            }
        }

        if self.locationArmed {
            let locationURL = self.paths.locationURL(directory: directory)
            do {
                try await self.storageActor.openLocationLogHeader(at: locationURL)
                guard await self.continueOpeningLifecycleOperation(generation) else { return false }
                if let lastKnownFix {
                    try await self.storageActor.appendLocationFix(lastKnownFix.carryForward(at: startedAt), at: locationURL)
                    guard await self.continueOpeningLifecycleOperation(generation) else { return false }
                }
                active.locationURL = locationURL
                self.openingSegment = active
            } catch {
                guard await self.continueOpeningLifecycleOperation(generation) else { return false }
                self.locationArmed = false
                self.locationProvider.stop()
                self.markPartial(&active, error: WatchCaptureFailureMapper.observerError(for: error))
                self.openingSegment = active
            }
        }

        manifest.partial = active.partialError != nil
        manifest.failureReason = active.partialError?.message
        manifest.state = .persisted
        active.manifest = manifest
        self.openingSegment = active
        do {
            try await self.storageActor.writeManifest(manifest, ensuringDirectory: false)
        } catch {
            guard await self.continueOpeningLifecycleOperation(generation) else { return false }
            var failedActive = active
            self.markPartial(&failedActive, error: WatchCaptureFailureMapper.observerError(for: error))
            self.openingSegment = failedActive
            throw error
        }
        guard await self.continueOpeningLifecycleOperation(generation) else { return false }
        self.activeSegment = active
        self.locationFixDeliveryClosed = false
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
        return true
    }

    /// An opening segment is intentionally kept out of `activeSegment` until
    /// its persisted manifest exists. If a Stop supersedes that opening while
    /// actor I/O is suspended, promote it only long enough for the established
    /// terminalization path to stop resources and retain durable media.
    func continueOpeningLifecycleOperation(
        _ generation: Int?,
        emptyDirectory: URL? = nil
    ) async -> Bool {
        guard let generation, !self.isLifecycleGenerationCurrent(generation) else { return true }
        if self.openingSegment != nil {
            await self.adoptOpeningFailureSegment()
        } else if let emptyDirectory {
            try? await self.storageActor.removeItem(at: emptyDirectory, transactionClass: .captureSafety)
        }
        _ = await self.continueLifecycleOperation(generation)
        return false
    }

    func adoptOpeningFailureSegment(
        _ explicitSegment: ActiveSegment? = nil,
        removeIfEmpty: Bool = true
    ) async {
        let segment = explicitSegment ?? self.openingSegment
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
        self.activeSegment = nil
        guard let segment else { return }
        if removeIfEmpty, await self.removeSegmentDirectoryIfMediaIsProvablyEmpty(segment.directoryURL) {
            return
        }
        self.activeSegment = segment
    }

    /// A directory is disposable only when every owner-media path is known empty.
    /// A size-query failure deliberately retains the directory for reconciliation.
    func removeSegmentDirectoryIfMediaIsProvablyEmpty(_ directory: URL) async -> Bool {
        await self.storageActor.removeSegmentDirectoryIfMediaIsProvablyEmpty(at: directory)
    }

    func startSegmentationTask() {
        self.segmentationTask?.cancel()
        self.segmentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(WatchCaptureTiming.segmentDurationSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.lifecycleSerializer.submit(.rollover)
                await self.settled()
            }
        }
    }

    func rolloverInner(generation: Int, ownerSessionID: String) async {
        self.locationFixDeliveryClosed = true
        await self.waitForAdmittedLocationFixes()
        guard await self.continueLifecycleOperation(generation) else { return }
        guard var segment = self.activeSegment else { return }
        let end = self.clock.now()
        self.activeSegment = nil
        self.currentAudioEnrollment = nil
        let audioDuration: TimeInterval?
        if self.audioArmed, segment.audioURL != nil {
            do {
                audioDuration = try self.audioRecorder.stop()
            } catch {
                audioDuration = nil
                self.markPartial(&segment, error: WatchCaptureFailureMapper.observerError(for: error))
            }
        } else {
            audioDuration = nil
        }
        self.rolloverPriorSegment = segment
        self.rolloverPriorAudioDuration = audioDuration

        var rolloverTerminalReason: WatchCaptureTerminalReason?
        var discardEmptySuccessorAfterStop = false
        do {
            guard try await self.openSegment(
                startedAt: end,
                ownerSessionID: ownerSessionID,
                generation: generation
            ) else { return }
            guard await self.continueLifecycleOperation(generation) else { return }
            guard let newSegment = self.activeSegment, newSegment.hasLiveSensor else {
                await self.adoptOpeningFailureSegment(self.activeSegment)
                rolloverTerminalReason = self.reopenFailureTerminalReason()
                throw WatchCaptureEngineError.audioStartFailed
            }
            self.status = self.statusForRunningSegment(newSegment)
        } catch WatchCaptureEngineError.audioStartFailed {
            await self.adoptOpeningFailureSegment(removeIfEmpty: false)
            rolloverTerminalReason = self.reopenFailureTerminalReason()
            discardEmptySuccessorAfterStop = true
        } catch {
            await self.adoptOpeningFailureSegment(
                removeIfEmpty: !self.openingSegmentHasPersistedManifest
            )
            rolloverTerminalReason = self.reopenFailureTerminalReason()
        }

        if let rolloverTerminalReason {
            await self.terminalize(
                reason: rolloverTerminalReason,
                disposition: .detectedStoppedItself,
                at: end,
                discardEmptyActiveSegment: discardEmptySuccessorAfterStop
            )
            return
        }
        guard await self.finalize(
            segment: segment,
            audioDuration: audioDuration,
            end: end,
            generation: generation
        ) else { return }
        self.rolloverPriorSegment = nil
        self.rolloverPriorAudioDuration = nil
        guard await self.continueLifecycleOperation(generation) else { return }
        await self.publishStatus(.observing)
        self.notifyPresentationChanged()
    }

    @discardableResult
    func finalize(
        segment: ActiveSegment,
        audioDuration: TimeInterval?,
        end: Date,
        renewLease: Bool = true,
        generation: Int? = nil
    ) async -> Bool {
        await self.waitForAdmittedLocationFixes()
        if let generation, !self.isLifecycleGenerationCurrent(generation) {
            return false
        }
        let prepared = await self.prepareFinalization(
            segment: segment,
            audioDuration: audioDuration,
            end: end
        )
        if let generation, !self.isLifecycleGenerationCurrent(generation) {
            return false
        }
        if renewLease, let verifiedAt = prepared.verifiedAudioAt {
            await self.replaceAudioTruthLease(verifiedAt: verifiedAt, generation: generation)
            if let generation, !self.isLifecycleGenerationCurrent(generation) {
                return false
            }
        }
        await self.persistFinalization(
            prepared,
            sessionID: self.currentSessionID,
            relayTrigger: .segmentFinalization
        )
        return true
    }

    func finalizeTerminalSegment(
        _ segment: ActiveSegment,
        audioDuration: TimeInterval?,
        end: Date
    ) async {
        let prepared = await self.prepareFinalization(
            segment: segment,
            audioDuration: audioDuration,
            end: end
        )
        await self.persistFinalization(
            prepared,
            sessionID: self.currentSessionID,
            relayTrigger: .segmentFinalization
        )
    }

    func prepareFinalization(
        segment: ActiveSegment,
        audioDuration: TimeInterval?,
        end: Date
    ) async -> PreparedFinalization {
        await self.waitForAdmittedLocationFixes()
        var segment = segment
        var manifest = segment.manifest
        // `.captured` is the durable intent record written before either media
        // side effect; `.persisted` proves the segment finished opening.
        let openingFailure = manifest.state == .captured
        let declaredSensorEvidence = await self.retainDeclaredSensors(
            &manifest,
            directory: segment.directoryURL,
            requirePositiveSize: openingFailure
        )
        let declaredSensors = declaredSensorEvidence.sensors
        var hasUncertainMedia = !declaredSensorEvidence.unknownPresence.isEmpty
        var duration = openingFailure
            ? max(manifest.duration, 0)
            : max(audioDuration ?? end.timeIntervalSince(manifest.startedAt), 0)
        manifest.duration = duration
        var verifiedAudioAt: Date?

        if declaredSensors.contains(.audio) {
            let audioURL = self.paths.audioURL(directory: segment.directoryURL)
            if declaredSensorEvidence.unknownPresence.contains(.audio) {
                manifest.partial = true
            } else {
                switch await self.audioProbeResult(at: audioURL) {
                case let .decodable(probedDuration):
                    duration = probedDuration
                    manifest.duration = probedDuration
                    verifiedAudioAt = manifest.startedAt.addingTimeInterval(probedDuration)
                case .confirmedUndecodable:
                    manifest.partial = true
                    if openingFailure {
                        manifest.lost = false
                    } else {
                        manifest.lost = true
                        manifest.failureReason = WatchCaptureTerminalReason.audioUndecodable.observerError.message
                        try? await self.storageActor.removeItem(at: audioURL, transactionClass: .captureSafety)
                    }
                case .ioUnknown:
                    manifest.partial = true
                    hasUncertainMedia = true
                }
            }
        }

        if declaredSensors.contains(.location) {
            let locationURL = self.paths.locationURL(directory: segment.directoryURL)
            if declaredSensorEvidence.unknownPresence.contains(.location) {
                manifest.partial = true
            } else {
                do {
                    let stats = try await self.storageActor.finalizeLocationLog(at: locationURL, armed: true)
                    manifest.fixCount = stats.fixCount
                    manifest.gap = stats.gap
                } catch {
                    self.markPartial(&segment, error: WatchCaptureFailureMapper.observerError(for: error))
                    manifest.partial = true
                    manifest.failureReason = segment.partialError?.message
                    hasUncertainMedia = true
                }
            }
        } else {
            manifest.fixCount = 0
            manifest.gap = false
        }

        if let partialError = segment.partialError {
            manifest.partial = true
            manifest.failureReason = partialError.message
        }

        let disposition: FinalizationDisposition
        if openingFailure, declaredSensors.isEmpty, !hasUncertainMedia {
            disposition = .discard
        } else if hasUncertainMedia {
            disposition = .retain
        } else {
            disposition = .queue
        }
        return PreparedFinalization(
            segment: segment,
            manifest: manifest,
            verifiedAudioAt: verifiedAudioAt,
            disposition: disposition
        )
    }

    func persistFinalization(
        _ prepared: PreparedFinalization,
        sessionID: String?,
        relayTrigger: RelayTrigger
    ) async {
        let segment = prepared.segment
        var manifest = prepared.manifest
        switch prepared.disposition {
        case .discard:
            guard await self.removeSegmentDirectoryIfMediaIsProvablyEmpty(segment.directoryURL) else {
                self.status = .needsAttention(.unavailable(reason: SourceVocabulary.watchStatusSaveFailed))
                return
            }
            return
        case .retain:
            do {
                try await self.storageActor.writeManifest(manifest, ensuringDirectory: false)
            } catch {
                self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
            }
            return
        case .queue:
            break
        }
        let finalSegment = self.paths.segmentString(
            for: manifest.startedAt,
            durationSeconds: max(manifest.duration, 1)
        )
        do {
            _ = try await self.storageActor.moveSegmentDirectoryIfNeeded(
                currentURL: segment.directoryURL,
                day: manifest.day,
                currentSegment: manifest.segment,
                finalSegment: finalSegment
            )
            manifest.segment = finalSegment
            manifest.state = .finalized
            try await self.storageActor.writeManifest(manifest, ensuringDirectory: false)
            manifest.state = .queued
            try await self.storageActor.writeManifest(manifest, ensuringDirectory: false)
            if manifest.partial {
                watchCaptureLog.error(
                    "watch segment partial id=\(manifest.id.uuidString, privacy: .public) state=queued"
                )
            }
            self.queuedCount += 1
            await self.incrementSegmentsProduced(sessionID: sessionID)
            self.requestRelayDrain(trigger: relayTrigger)
        } catch {
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
        }
    }

    func recoverUnclean(_ entry: WatchCaptureCatalogEntry, sessionID: String?) async throws {
        var manifest = entry.manifest
        manifest.partial = true
        let segment = ActiveSegment(
            directoryURL: entry.directoryURL,
            manifest: manifest,
            audioURL: manifest.sensors.contains(.audio)
                ? self.paths.audioURL(directory: entry.directoryURL) : nil,
            locationURL: manifest.sensors.contains(.location)
                ? self.paths.locationURL(directory: entry.directoryURL) : nil,
            partialError: nil,
            hasElapsedLocationCoverage: false
        )
        var prepared = await self.prepareFinalization(
            segment: segment,
            audioDuration: nil,
            end: manifest.startedAt.addingTimeInterval(manifest.duration)
        )
        if prepared.manifest.lost {
            var lostManifest = prepared.manifest
            lostManifest.failureReason = "audio unavailable after restart"
            prepared = PreparedFinalization(
                segment: prepared.segment,
                manifest: lostManifest,
                verifiedAudioAt: prepared.verifiedAudioAt,
                disposition: prepared.disposition
            )
            self.status = .needsAttention(.unavailable(reason: "audio unavailable after restart"))
        }
        await self.persistFinalization(
            prepared,
            sessionID: sessionID,
            relayTrigger: .launchReconciliation
        )
    }

    func retainDeclaredSensors(
        _ manifest: inout WatchSegmentManifest,
        directory: URL,
        requirePositiveSize: Bool
    ) async -> DeclaredSensorEvidence {
        var unknownPresence: [WatchSensor] = []
        var retainedSensors: [WatchSensor] = []
        for sensor in manifest.sensors {
            let url: URL
            switch sensor {
            case .audio:
                url = self.paths.audioURL(directory: directory)
            case .location:
                url = self.paths.locationURL(directory: directory)
            }
            guard requirePositiveSize else {
                if await self.storageActor.fileExists(at: url, transactionClass: .captureSafety) {
                    retainedSensors.append(sensor)
                }
                continue
            }
            do {
                if try await self.storageActor.fileSize(at: url, transactionClass: .captureSafety) > 0 {
                    retainedSensors.append(sensor)
                }
            } catch {
                unknownPresence.append(sensor)
                retainedSensors.append(sensor)
            }
        }
        manifest.sensors = retainedSensors
        return DeclaredSensorEvidence(
            sensors: manifest.sensors,
            unknownPresence: unknownPresence
        )
    }

    func audioProbeResult(at url: URL) async -> WatchAudioProbeResult {
        await self.storageActor.probeAudio(at: url)
    }

    func incrementSegmentsProduced(sessionID: String?) async {
        guard let sessionID else { return }
        if var record = try? await self.storageActor.readSessionRecord(transactionClass: .maintenance), record.sessionID == sessionID {
            record.segmentsProduced += 1
            do {
                try await self.storageActor.writeSessionRecord(record, transactionClass: .maintenance)
            } catch {
                watchCaptureLog.error("watch segment count write failed: \(String(describing: error), privacy: .public)")
                self.persistenceAdvisory = .sessionRecordWriteFailed
                return
            }
        }
        guard var entry = await self.storageActor.sessionHistoryEntry(
            sessionID: sessionID,
            asOf: self.clock.now(),
            transactionClass: .maintenance
        ) else { return }
        if let record = try? await self.storageActor.readSessionRecord(transactionClass: .maintenance),
           record.sessionID == sessionID,
           record.state == .terminal,
           let terminalReason = record.terminalReason,
           let terminalDisposition = record.terminalDisposition,
           let terminalAt = record.terminalAt {
            entry.terminalReason = terminalReason
            entry.terminalDisposition = terminalDisposition
            entry.terminalAt = terminalAt
            entry.noticeOwed = record.noticeOwed
        }
        entry.segmentsProduced += 1
        do {
            try await self.storageActor.upsertSessionHistory(
                entry,
                asOf: self.clock.now(),
                transactionClass: .maintenance
            )
        } catch {
            watchCaptureLog.error("watch segment history write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
    }

    func handleFix(_ fix: WatchLocationFix, for expectedSegmentID: UUID?) async {
        self.lastKnownFix = fix
        guard self.locationArmed else { return }
        guard let expectedSegmentID,
              var segment = self.activeSegment,
              segment.manifest.id == expectedSegmentID,
              let locationURL = segment.locationURL
        else { return }
        do {
            try await self.storageActor.appendLocationFix(fix, at: locationURL)
            guard var currentSegment = self.activeSegment,
                  currentSegment.manifest.id == expectedSegmentID
            else { return }
            currentSegment.hasElapsedLocationCoverage = true
            self.activeSegment = currentSegment
            self.locationAdvisory = nil
            self.notifyPresentationChanged()
        } catch {
            self.markPartial(&segment, error: WatchCaptureFailureMapper.observerError(for: error))
            self.activeSegment = segment
            self.locationAdvisory = .writeFailed
            self.locationArmed = false
            self.locationProvider.stop()
            if self.audioArmed, segment.audioURL != nil {
                watchCaptureLog.info(
                    "watch sensor lost id=\(segment.manifest.id.uuidString, privacy: .public) sensor=location survivor=audio"
                )
            }
            self.notifyPresentationChanged()
        }
    }

    func handleAuthorizationChanged(_ authorization: WatchLocationAuthorization) {
        guard self.locationArmed, authorization != .authorized else { return }
        self.locationArmed = false
        self.locationProvider.stop()
        self.locationAdvisory = .authorizationLost
        if var segment = self.activeSegment {
            self.markPartial(&segment, error: .unavailable(reason: SourceVocabulary.watchLocationUnavailable))
            self.activeSegment = segment
        }
        if self.audioArmed, let segment = self.activeSegment, segment.audioURL != nil {
            watchCaptureLog.info(
                "watch sensor lost id=\(segment.manifest.id.uuidString, privacy: .public) sensor=location survivor=audio"
            )
        }
        self.notifyPresentationChanged()
    }

    func handleLocationFailure(_ error: any Error) {
        guard self.locationArmed else { return }
        self.locationAdvisory = .providerFailed
        if var segment = self.activeSegment {
            self.markPartial(&segment, error: WatchCaptureFailureMapper.observerError(for: error))
            self.activeSegment = segment
        }
        self.notifyPresentationChanged()
    }

    func markPartial(_ segment: inout ActiveSegment, error: ObserverError) {
        segment.partialError = error
        segment.manifest.partial = true
        segment.manifest.failureReason = error.message
    }

    func statusForRunningSegment(_ segment: ActiveSegment) -> WatchCaptureRuntimeStatus {
        _ = segment
        return .active
    }

    func installAudioSessionObservers(source: WatchCaptureSourceToken) {
        self.removeAudioSessionObservers()
        let notificationHandoff = self.audioSessionNotificationHandoff
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self, source] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            notificationHandoff { [weak self, source] in
                self?.handleInterruption(type, source: source)
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self, source] _ in
            notificationHandoff { [weak self, source] in
                self?.handleRouteChange(source: source)
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: nil
        ) { [weak self, source] _ in
            notificationHandoff { [weak self, source] in
                self?.submitTerminalIntent(
                    reason: .audioMediaServicesLost,
                    disposition: .detectedStoppedItself,
                    source: source
                )
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self, source] _ in
            notificationHandoff { [weak self, source] in
                self?.submitTerminalIntent(
                    reason: .audioMediaServicesReset,
                    disposition: .detectedStoppedItself,
                    source: source
                )
            }
        })
    }

    func removeAudioSessionObservers() {
        for observer in self.audioSessionObservers {
            self.notificationCenter.removeObserver(observer)
        }
        self.audioSessionObservers = []
    }

    func handleInterruption(_ type: AVAudioSession.InterruptionType, source: WatchCaptureSourceToken) {
        switch type {
        case .began:
            self.submitTerminalIntent(
                reason: .audioInterrupted,
                disposition: .detectedStoppedItself,
                source: source
            )
        case .ended:
            break
        @unknown default:
            break
        }
    }

    func handleRouteChange(source: WatchCaptureSourceToken) {
        guard self.activeSegment != nil, !self.audioSession.hasSuitableInput else { return }
        self.submitTerminalIntent(
            reason: .audioRouteUnavailable,
            disposition: .detectedStoppedItself,
            source: source
        )
    }

    func submitTerminalIntent(
        reason: WatchCaptureTerminalReason,
        disposition: WatchCaptureTerminalDisposition,
        livenessEvidence: WatchCaptureLivenessEvidence? = nil,
        source: WatchCaptureSourceToken
    ) {
        self.lifecycleSerializer.submit(.terminal(.init(
            reason: reason,
            disposition: disposition,
            livenessEvidence: livenessEvidence,
            source: source
        )))
    }

    func notifyPresentationChanged() {
        self.onPresentationChanged?(self.ownerPresentation)
    }

    func requestRelayDrain(trigger: RelayTrigger) {
        let handoff = self.signposter.begin(
            .relayHandoff,
            fields: WatchSignpostFields(trigger: trigger)
        )
        self.onRelayDrainRequested?(trigger)
        self.signposter.end(handoff, fields: WatchSignpostFields(trigger: trigger, result: .completed))
    }

    @discardableResult
    func mintSessionIdentity(startedAt: Date) async -> Bool {
        guard self.currentSessionID == nil, self.sessionStartedAt == nil else {
            return self.currentSessionID != nil && self.sessionStartedAt != nil
        }
        let sessionID = UUID().uuidString
        let incremented: WatchCaptureSessionHistoryCounter
        do {
            guard let counter = try await self.storageActor.incrementLifetimeSessionCounter() else {
                watchCaptureLog.error("watch session counter unreadable")
                self.persistenceAdvisory = .sessionRecordWriteFailed
                return false
            }
            incremented = counter
        } catch {
            watchCaptureLog.error("watch session counter write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
            return false
        }
        // A session is live only when its lifetime count and history identity both persist.
        guard await self.upsertSessionHistory(
            sessionID: sessionID,
            startedAt: startedAt,
            terminalAt: nil,
            noticeOwed: false,
            liveness: nil,
            environment: nil,
            transactionClass: .captureSafety
        ) else {
            do {
                try await self.storageActor.revertLifetimeSessionCounterIncrement(incremented)
            } catch {
                watchCaptureLog.error("watch session counter rollback failed: \(String(describing: error), privacy: .public)")
            }
            self.persistenceAdvisory = .sessionRecordWriteFailed
            return false
        }
        self.currentSessionID = sessionID
        self.sessionStartedAt = startedAt
        return true
    }

    @discardableResult
    func beginStatusSession(startedAt: Date) async -> Bool {
        await self.mintSessionIdentity(startedAt: startedAt)
    }

    func publishStatus(_ phase: WatchStatusContext.Phase) async {
        self.statusSeq += 1
        let asOf = self.clock.now()
        if phase != .idle, self.currentSessionID == nil || self.sessionStartedAt == nil {
            _ = await self.beginStatusSession(startedAt: asOf)
        }
        let diagnosticsInterval = self.signposter.begin(.diagnosticsCollection)
        let diagnosticsEnvelope = await self.onDiagnosticsEnvelopeRequested?(asOf)
        self.signposter.end(
            diagnosticsInterval,
            fields: WatchSignpostFields(result: .completed)
        )
        let context = WatchStatusContext(
            phase: phase,
            sessionID: self.currentSessionID,
            startedAt: self.sessionStartedAt,
            asOf: asOf,
            seq: self.statusSeq,
            queuedCount: max(0, self.queuedCount),
            transferringCount: max(0, self.transferringCount),
            audioTerminalReason: self.terminalReason,
            audioTerminalDisposition: self.terminalDisposition,
            diagnosticsEnvelope: diagnosticsEnvelope
        )
        self.onPublishStatus?(context)
    }

    @discardableResult
    func refreshWristAlertState(
        requestIfNotDetermined: Bool,
        generation: Int? = nil
    ) async -> (WatchNotificationAuthorizationStatus, WatchNotificationAlertSetting)? {
        var authorization = await self.notificationScheduler.authorizationStatus()
        if let generation {
            guard await self.continueLifecycleOperation(generation) else { return nil }
        }
        if authorization == .notDetermined, requestIfNotDetermined {
            do {
                authorization = try await self.notificationScheduler.requestAuthorization()
                if let generation {
                    guard await self.continueLifecycleOperation(generation) else { return nil }
                }
            } catch {
                watchCaptureLog.error("watch notification authorization failed: \(String(describing: error), privacy: .public)")
                if let generation {
                    guard await self.continueLifecycleOperation(generation) else { return nil }
                }
            }
        }
        let alertSetting = await self.notificationScheduler.alertSetting()
        if let generation {
            guard await self.continueLifecycleOperation(generation) else { return nil }
        }
        self.notificationAuthorizationStatus = authorization
        self.notificationAlertSetting = alertSetting
        self.wristAlertAssurance = watchWristAlertAssurance(
            authorization: authorization,
            alertSetting: alertSetting
        )
        return (authorization, alertSetting)
    }

    func setSettingsRouteIfVacant(_ route: WatchCaptureSettingsRoute) {
        if self.settingsRoute == nil {
            self.settingsRoute = route
        }
    }

    func upsertSessionHistory(
        record: WatchCaptureSessionRecord? = nil,
        sessionID: String? = nil,
        startedAt: Date? = nil,
        terminalAt: Date? = nil,
        noticeOwed: Bool? = nil,
        liveness: WatchCaptureLivenessEvidence?,
        environment: WatchRelayDiagnosticsEnvironmentSnapshot?,
        transactionClass: WatchCaptureStorageTransactionClass
    ) async -> Bool {
        let id = record?.sessionID ?? sessionID ?? self.currentSessionID
        let start = record?.startedAt ?? startedAt ?? self.sessionStartedAt
        guard let id, let start else { return false }
        let prior = await self.storageActor.sessionHistoryEntry(
            sessionID: id,
            asOf: self.clock.now(),
            transactionClass: transactionClass
        )
        let terminalSnapshotExists = prior?.terminalAt != nil
        let terminalEnvironment = environment ?? self.terminalEnvironmentSnapshot
        let entry = WatchCaptureSessionHistoryEntry(
            sessionID: id,
            startedAt: start,
            terminalAt: record?.terminalAt ?? terminalAt ?? prior?.terminalAt,
            terminalReason: record?.terminalReason ?? self.terminalReason ?? prior?.terminalReason,
            terminalDisposition: record?.terminalDisposition ?? self.terminalDisposition ?? prior?.terminalDisposition,
            startRefusalReason: self.startRefusalReason ?? prior?.startRefusalReason,
            settingsRoute: self.settingsRoute ?? prior?.settingsRoute,
            noticeOwed: record?.noticeOwed ?? noticeOwed ?? prior?.noticeOwed ?? false,
            noticeDecision: prior?.noticeDecision,
            noticeDelivered: prior?.noticeDelivered,
            notificationAuthorizationStatus: prior?.notificationAuthorizationStatus,
            notificationAlertSetting: prior?.notificationAlertSetting,
            wristAlertAssurance: prior?.wristAlertAssurance,
            audioArmed: terminalSnapshotExists ? prior?.audioArmed ?? false : self.audioArmed,
            audioSessionIsActive: terminalSnapshotExists ? prior?.audioSessionIsActive ?? false : self.audioSessionIsActive,
            locationArmed: terminalSnapshotExists ? prior?.locationArmed ?? false : self.locationArmed,
            segmentsProduced: record?.segmentsProduced ?? prior?.segmentsProduced ?? 0,
            batteryLevelAtEnd: terminalEnvironment?.watchBatteryLevel.value ?? prior?.batteryLevelAtEnd,
            batteryStateAtEnd: terminalEnvironment?.watchBatteryState.value ?? prior?.batteryStateAtEnd,
            lowPowerModeEnabledAtEnd: terminalEnvironment?.watchLowPowerModeEnabled.value ?? prior?.lowPowerModeEnabledAtEnd,
            thermalStateAtEnd: terminalEnvironment?.watchThermalState.value ?? prior?.thermalStateAtEnd,
            lastVerifiedAudioAt: terminalSnapshotExists ? prior?.lastVerifiedAudioAt : self.lastVerifiedAudioAt,
            lastAudioCurrentTime: liveness?.audioCurrentTime ?? (terminalSnapshotExists ? prior?.lastAudioCurrentTime : self.lastAudioCurrentTime),
            zeroAudioCurrentTimeObservationCount: liveness?.zeroAudioCurrentTimeObservationCount ?? (terminalSnapshotExists ? prior?.zeroAudioCurrentTimeObservationCount : self.zeroAudioCurrentTimeObservationCount),
            locationAdvisory: self.locationAdvisory ?? prior?.locationAdvisory,
            persistenceAdvisory: self.persistenceAdvisory ?? prior?.persistenceAdvisory
        )
        do {
            try await self.storageActor.upsertSessionHistory(
                entry,
                asOf: self.clock.now(),
                transactionClass: transactionClass
            )
            return true
        } catch {
            watchCaptureLog.error("watch session history write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func removeAudioTruthLease() {
        self.notificationScheduler.removePending(identifier: WatchNoticeIdentifiers.lease)
        self.leaseIsArmed = false
    }

    func reopenFailureTerminalReason() -> WatchCaptureTerminalReason {
        self.audioRecorder.microphonePermission == .denied ? .microphonePermissionRevoked : .audioStartFailed
    }

    func addWatchNotification(identifier: String, copy: WatchNoticeCopy, triggerDate: Date?) async -> Bool {
        do {
            try await self.notificationScheduler.add(
                identifier: identifier,
                title: copy.title,
                body: copy.body,
                triggerDate: triggerDate
            )
            return true
        } catch {
            watchCaptureLog.error("watch notification add failed id=\(identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func replaceAudioTruthLease(verifiedAt: Date, generation: Int? = nil) async {
        self.lastVerifiedAudioAt = verifiedAt
        guard let (authorization, alertSetting) = await self.refreshWristAlertState(
            requestIfNotDetermined: false,
            generation: generation
        ) else { return }
        let decision = watchNoticeDecision(
            authorizationStatus: authorization,
            alertSetting: alertSetting,
            disposition: .inferredStoppedItself,
            reason: .processExitedWhileActive,
            leaseArmed: self.leaseIsArmed
        )
        switch decision {
        case let .schedule(copy):
            let deadline = verifiedAt.addingTimeInterval(WatchCaptureTiming.segmentDurationSeconds * 2)
            if await self.addWatchNotification(
                identifier: WatchNoticeIdentifiers.lease,
                copy: copy,
                triggerDate: deadline
            ) {
                if let generation {
                    guard await self.continueLifecycleOperation(generation) else { return }
                }
                self.leaseIsArmed = true
            } else {
                if let generation {
                    guard await self.continueLifecycleOperation(generation) else { return }
                }
                self.removeAudioTruthLease()
            }
        case let .cannotSchedule(route):
            self.removeAudioTruthLease()
            self.setSettingsRouteIfVacant(route)
        case .cancelLease, .none:
            self.removeAudioTruthLease()
        }
    }

    func submitTerminalNotice(expected terminal: WatchCaptureTerminalTuple) async {
        guard terminal.noticeOwed,
              let reason = terminal.reason,
              let disposition = terminal.disposition,
              disposition != .ownerStopped,
              let copy = WatchNoticeCopy(reason: reason, disposition: disposition)
        else { return }

        guard let (authorization, alertSetting) = await self.refreshWristAlertState(requestIfNotDetermined: false) else {
            return
        }
        let decision = watchNoticeDecision(
            authorizationStatus: authorization,
            alertSetting: alertSetting,
            disposition: disposition,
            reason: reason,
            leaseArmed: self.leaseIsArmed
        )
        switch decision {
        case let .schedule(copy):
            let delivered = await self.addWatchNotification(
                identifier: WatchNoticeIdentifiers.notice,
                copy: copy,
                triggerDate: nil
            )
            await self.performSignposted(.sessionHistory) {
                _ = await self.storageActor.mergeTerminalNoticeMetadata(
                    expected: terminal,
                    update: WatchCaptureTerminalNoticeMetadata(
                        noticeDecision: decision.historyRawValue,
                        noticeDelivered: delivered,
                        notificationAuthorizationStatus: authorization,
                        notificationAlertSetting: alertSetting,
                        wristAlertAssurance: watchWristAlertAssurance(
                            authorization: authorization,
                            alertSetting: alertSetting
                        )
                    )
                )
            }
            if delivered {
                await self.performSignposted(.sessionHistory) {
                    _ = await self.storageActor.mergeTerminalNoticeMetadata(
                        expected: terminal,
                        update: WatchCaptureTerminalNoticeMetadata(noticeOwed: false)
                    )
                }
            }
        case let .cannotSchedule(route):
            let resolvedRoute: WatchCaptureSettingsRoute = copy == .microphoneAccessNeeded ? .microphone : route
            if terminal.sessionID == self.currentSessionID {
                self.setSettingsRouteIfVacant(resolvedRoute)
            }
            await self.performSignposted(.sessionHistory) {
                _ = await self.storageActor.mergeTerminalNoticeMetadata(
                    expected: terminal,
                    update: WatchCaptureTerminalNoticeMetadata(
                        noticeDecision: decision.historyRawValue,
                        noticeDelivered: false,
                        notificationAuthorizationStatus: authorization,
                        notificationAlertSetting: alertSetting,
                        wristAlertAssurance: watchWristAlertAssurance(
                            authorization: authorization,
                            alertSetting: alertSetting
                        ),
                        settingsRoute: resolvedRoute
                    )
                )
            }
        case .cancelLease:
            if terminal.sessionID == self.currentSessionID {
                self.removeAudioTruthLease()
            }
            await self.performSignposted(.sessionHistory) {
                _ = await self.storageActor.mergeTerminalNoticeMetadata(
                    expected: terminal,
                    update: WatchCaptureTerminalNoticeMetadata(
                        noticeDecision: decision.historyRawValue,
                        noticeDelivered: false,
                        notificationAuthorizationStatus: authorization,
                        notificationAlertSetting: alertSetting,
                        wristAlertAssurance: watchWristAlertAssurance(
                            authorization: authorization,
                            alertSetting: alertSetting
                        )
                    )
                )
            }
        case .none:
            await self.performSignposted(.sessionHistory) {
                _ = await self.storageActor.mergeTerminalNoticeMetadata(
                    expected: terminal,
                    update: WatchCaptureTerminalNoticeMetadata(
                        noticeDecision: decision.historyRawValue,
                        noticeDelivered: false,
                        notificationAuthorizationStatus: authorization,
                        notificationAlertSetting: alertSetting,
                        wristAlertAssurance: watchWristAlertAssurance(
                            authorization: authorization,
                            alertSetting: alertSetting
                        )
                    )
                )
            }
        }
    }

    func startHeartbeatTask(source: WatchCaptureSourceToken) {
        self.cancelHeartbeatTask()
        self.heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(Self.heartbeatIntervalSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.activeSegment != nil else { return }
                guard self.evaluateAudioLiveness(source: source) else { return }
                await self.publishStatus(.observing)
            }
        }
    }

    func cancelHeartbeatTask() {
        self.heartbeatTask?.cancel()
        self.heartbeatTask = nil
    }

    func writeActiveSessionRecord(startedAt: Date) async {
        guard let currentSessionID else { return }
        let record = WatchCaptureSessionRecord(
            sessionID: currentSessionID,
            startedAt: startedAt,
            state: .active,
            terminalReason: nil,
            terminalDisposition: nil,
            terminalAt: nil,
            noticeOwed: false,
            segmentsProduced: 0
        )
        do {
            try await self.storageActor.writeSessionRecord(record, transactionClass: .captureSafety)
            _ = await self.upsertSessionHistory(
                record: record,
                liveness: nil,
                environment: nil,
                transactionClass: .captureSafety
            )
        } catch {
            watchCaptureLog.error("watch active session record write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
    }

    @discardableResult
    func persistTerminalFact(
        reason: WatchCaptureTerminalReason,
        disposition: WatchCaptureTerminalDisposition,
        at date: Date,
        liveness: WatchCaptureLivenessEvidence? = nil,
        sessionID: String? = nil,
        startedAt: Date? = nil
    ) async -> WatchCaptureSessionRecord? {
        self.terminalReason = reason
        self.terminalDisposition = disposition
        if reason == .microphonePermissionRevoked {
            self.setSettingsRouteIfVacant(.microphone)
        }
        guard let currentSessionID = sessionID ?? self.currentSessionID,
              let sessionStartedAt = startedAt ?? self.sessionStartedAt
        else { return nil }
        let priorRecord = try? await self.storageActor.readSessionRecord(transactionClass: .captureSafety)
        let record = WatchCaptureSessionRecord(
            sessionID: currentSessionID,
            startedAt: sessionStartedAt,
            state: .terminal,
            terminalReason: reason,
            terminalDisposition: disposition,
            terminalAt: date,
            noticeOwed: disposition != .ownerStopped,
            segmentsProduced: priorRecord?.segmentsProduced ?? 0
        )
        let environment = self.environmentProvider.snapshot()
        self.terminalEnvironmentSnapshot = environment
        do {
            try await self.storageActor.writeSessionRecord(record, transactionClass: .captureSafety)
        } catch {
            watchCaptureLog.error("watch terminal session record write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        if !(await self.upsertSessionHistory(
            record: record,
            liveness: liveness,
            environment: environment,
            transactionClass: .captureSafety
        )) {
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        return record
    }

    private func reconcileSessionRecord(generation: Int) async -> ReconcileReadinessSeed? {
        self.captureSafetyReadinessFailed = false
        let record: WatchCaptureSessionRecord?
        do {
            record = try await self.performSignposted(.sessionRecord) {
                try await self.storageActor.readSessionRecord(transactionClass: .captureSafety)
            }
        } catch {
            watchCaptureLog.error("watch session record unreadable: \(String(describing: error), privacy: .public)")
            self.captureSafetyReadinessFailed = true
            self.persistenceAdvisory = .sessionRecordUnreadable
            self.terminalReason = .processExitedWhileActive
            self.terminalDisposition = .inferredStoppedItself
            if !self.admittedStartPending {
                self.status = .needsAttention(
                    WatchCaptureTerminalReason.processExitedWhileActive.observerError(disposition: .inferredStoppedItself)
                )
            }
            self.removeAudioTruthLease()
            return ReconcileReadinessSeed(reconciledSessionID: nil, deferredTerminalNotice: nil)
        }
        guard let record else {
            return ReconcileReadinessSeed(reconciledSessionID: nil, deferredTerminalNotice: nil)
        }

        self.currentSessionID = record.sessionID
        self.sessionStartedAt = record.startedAt
        let emptyTerminal = WatchCaptureTerminalTuple(
            sessionID: record.sessionID,
            startedAt: record.startedAt,
            reason: nil,
            disposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        let resolution: WatchCaptureTerminalTupleResolution
        switch record.state {
        case .active:
            let repair = await self.storageActor.resolveAndPersistTerminalTuple(
                recordProposal: record,
                proposedTerminal: emptyTerminal,
                asOf: self.clock.now()
            )
            if case .resolvedAndPersisted = repair {
                resolution = repair
            } else {
                let inferred = WatchCaptureTerminalTuple(
                    sessionID: record.sessionID,
                    startedAt: record.startedAt,
                    reason: .processExitedWhileActive,
                    disposition: .inferredStoppedItself,
                    terminalAt: self.clock.now(),
                    noticeOwed: true
                )
                self.terminalClaimedSessionIDs.insert(record.sessionID)
                resolution = await self.storageActor.resolveAndPersistTerminalTuple(
                    recordProposal: record,
                    proposedTerminal: inferred,
                    asOf: self.clock.now()
                )
            }
        case .terminal:
            let proposed = WatchCaptureTerminalTuple(
                sessionID: record.sessionID,
                startedAt: record.startedAt,
                reason: record.terminalReason,
                disposition: record.terminalDisposition,
                terminalAt: record.terminalAt,
                noticeOwed: record.noticeOwed
            )
            resolution = await self.storageActor.resolveAndPersistTerminalTuple(
                recordProposal: record,
                proposedTerminal: proposed,
                asOf: self.clock.now()
            )
        }

        guard case let .resolvedAndPersisted(tuple) = resolution,
              let reason = tuple.reason,
              let disposition = tuple.disposition,
              self.isLifecycleGenerationCurrent(generation)
        else {
            self.captureSafetyReadinessFailed = true
            self.persistenceAdvisory = .sessionRecordWriteFailed
            self.terminalReason = .processExitedWhileActive
            self.terminalDisposition = .inferredStoppedItself
            if !self.admittedStartPending {
                self.status = .needsAttention(
                    WatchCaptureTerminalReason.processExitedWhileActive.observerError(disposition: .inferredStoppedItself)
                )
            }
            self.removeAudioTruthLease()
            return ReconcileReadinessSeed(reconciledSessionID: record.sessionID, deferredTerminalNotice: nil)
        }

        self.removeAudioTruthLease()
        let shouldSurfaceTerminal: Bool
        switch record.state {
        case .active:
            shouldSurfaceTerminal = tuple.noticeOwed
        case .terminal:
            shouldSurfaceTerminal = disposition == .ownerStopped || tuple.noticeOwed
        }
        if shouldSurfaceTerminal {
            self.terminalReason = reason
            self.terminalDisposition = disposition
            if !self.admittedStartPending {
                if disposition == .ownerStopped {
                    self.status = .off
                } else {
                    self.status = .needsAttention(reason.observerError(disposition: disposition))
                }
            }
        }
        return ReconcileReadinessSeed(
            reconciledSessionID: record.sessionID,
            deferredTerminalNotice: tuple.noticeOwed ? tuple : nil
        )
    }

    func evaluateAudioLiveness(source: WatchCaptureSourceToken) -> Bool {
        guard self.activeSegment != nil, self.audioArmed else {
            self.zeroAudioCurrentTimeObservationCount = 0
            self.lastAudioCurrentTime = nil
            return true
        }
        guard self.audioRecorder.isRecording else {
            let liveness = WatchCaptureLivenessEvidence(
                audioCurrentTime: nil,
                zeroAudioCurrentTimeObservationCount: self.zeroAudioCurrentTimeObservationCount
            )
            self.zeroAudioCurrentTimeObservationCount = 0
            self.submitTerminalIntent(
                reason: .audioRecorderStopped,
                disposition: .detectedStoppedItself,
                livenessEvidence: liveness,
                source: source
            )
            return false
        }
        let currentTime = self.audioRecorder.currentTime
        defer { self.lastAudioCurrentTime = currentTime }
        guard let lastAudioCurrentTime else {
            if currentTime == 0 {
                self.zeroAudioCurrentTimeObservationCount += 1
            }
            return true
        }
        if currentTime > lastAudioCurrentTime {
            self.zeroAudioCurrentTimeObservationCount = 0
            return true
        }
        if currentTime == 0 {
            if lastAudioCurrentTime == 0 {
                self.zeroAudioCurrentTimeObservationCount += 1
            }
            guard self.zeroAudioCurrentTimeObservationCount >= Self.zeroAudioCurrentTimeObservationLimit else {
                return true
            }
        }
        let liveness = WatchCaptureLivenessEvidence(
            audioCurrentTime: currentTime,
            zeroAudioCurrentTimeObservationCount: self.zeroAudioCurrentTimeObservationCount
        )
        self.zeroAudioCurrentTimeObservationCount = 0
        self.submitTerminalIntent(
            reason: .audioClockStalled,
            disposition: .detectedStoppedItself,
            livenessEvidence: liveness,
            source: source
        )
        return false
    }

    func terminalize(
        reason: WatchCaptureTerminalReason,
        disposition: WatchCaptureTerminalDisposition,
        at date: Date,
        liveness: WatchCaptureLivenessEvidence? = nil,
        discardEmptyActiveSegment: Bool = false
    ) async {
        let sessionID = self.currentSessionID
        if let sessionID {
            guard !self.terminalClaimedSessionIDs.contains(sessionID) else { return }
            self.terminalClaimedSessionIDs.insert(sessionID)
            self.lifecycleState = .stopping(sessionID: sessionID)
        }

        self.locationFixDeliveryClosed = true
        await self.waitForAdmittedLocationFixes()
        var segment = self.activeSegment
        self.activeSegment = nil
        let rolloverSegment = self.rolloverPriorSegment
        let rolloverAudioDuration = self.rolloverPriorAudioDuration
        self.rolloverPriorSegment = nil
        self.rolloverPriorAudioDuration = nil
        self.cancelHeartbeatTask()
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.removeAudioSessionObservers()
        self.locationProvider.stop()
        self.currentAudioEnrollment = nil

        let audioDuration: TimeInterval?
        if self.audioArmed, segment?.audioURL != nil {
            do {
                audioDuration = try self.audioRecorder.stop()
            } catch {
                audioDuration = nil
                if var active = segment {
                    self.markPartial(&active, error: WatchCaptureFailureMapper.observerError(for: error))
                    segment = active
                }
            }
        } else {
            audioDuration = nil
        }

        if discardEmptyActiveSegment,
           let activeSegment = segment,
           await self.removeSegmentDirectoryIfMediaIsProvablyEmpty(activeSegment.directoryURL) {
            segment = nil
        }

        self.audioArmed = false
        self.locationArmed = false
        self.lastAudioCurrentTime = nil
        self.zeroAudioCurrentTimeObservationCount = 0
        if self.audioSessionIsActive {
            try? self.audioSession.setActive(false, options: [])
            self.audioSessionIsActive = false
        }
        self.removeAudioTruthLease()
        self.terminalReason = reason
        self.terminalDisposition = disposition
        if reason == .microphonePermissionRevoked {
            self.setSettingsRouteIfVacant(.microphone)
        }

        switch disposition {
        case .ownerStopped:
            self.status = .off
        case .detectedStoppedItself, .inferredStoppedItself:
            self.status = .needsAttention(reason.observerError(disposition: disposition))
        }
        await self.publishStatus(.idle)
        self.notifyPresentationChanged()

        let record = await self.persistTerminalFact(
            reason: reason,
            disposition: disposition,
            at: date,
            liveness: liveness,
            sessionID: sessionID,
            startedAt: self.sessionStartedAt
        )
        self.notifyPresentationChanged()

        if let segment {
            await self.finalizeTerminalSegment(segment, audioDuration: audioDuration, end: date)
        }
        if let rolloverSegment {
            await self.finalizeTerminalSegment(
                rolloverSegment,
                audioDuration: rolloverAudioDuration,
                end: date
            )
        }
        self.notifyPresentationChanged()
        if let record {
            await self.submitTerminalNotice(expected: WatchCaptureTerminalTuple(
                sessionID: record.sessionID,
                startedAt: record.startedAt,
                reason: record.terminalReason,
                disposition: record.terminalDisposition,
                terminalAt: record.terminalAt,
                noticeOwed: record.noticeOwed
            ))
        }
    }

    @discardableResult
    func refreshRelayCountsFromDiskCatalog() async -> WatchCaptureCatalog {
        let catalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
        self.applyRelayCounts(self.relayCounts(from: catalog))
        self.applyCatalogAdvisory(catalog.rootState)
        return catalog
    }

    private func relayCounts(from catalog: WatchCaptureCatalog) -> RelayCounts {
        let entries = catalog.entries
        return RelayCounts(
            queued: entries.filter { $0.manifest.state == .queued }.count,
            transferring: entries.filter { $0.manifest.state == .transferring }.count,
            confirming: entries.filter { $0.manifest.state == .delivered }.count,
            handedOff: entries.filter {
                $0.manifest.state == .acked || $0.manifest.state == .safeToDelete
            }.count
        )
    }

    private func applyRelayCounts(_ counts: RelayCounts) {
        self.queuedCount = counts.queued
        self.transferringCount = counts.transferring
        self.confirmingCount = counts.confirming
        self.handedOffCount = counts.handedOff
    }

    func applyCatalogAdvisory(_ rootState: WatchCaptureCatalogRootState) {
        switch rootState {
        case .complete, .emptyComplete:
            if self.persistenceAdvisory == .manifestCatalogPartial
                || self.persistenceAdvisory == .manifestCatalogUnavailable {
                self.persistenceAdvisory = nil
            }
        case .partial:
            self.persistenceAdvisory = .manifestCatalogPartial
        case .unavailable:
            self.persistenceAdvisory = .manifestCatalogUnavailable
        }
    }

    func catalogResult(_ rootState: WatchCaptureCatalogRootState) -> RelayResult {
        switch rootState {
        case .complete, .emptyComplete:
            .completed
        case .partial:
            .partial
        case .unavailable:
            .failed
        }
    }
}
