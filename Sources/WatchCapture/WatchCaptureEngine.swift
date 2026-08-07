// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

private let watchCaptureLog = Logger(subsystem: "app.solstone.swift", category: "watch-capture")

@MainActor
final class WatchCaptureEngine {
    private enum LifecycleState: Equatable, Sendable {
        case idle
        case reconciling
        case starting
        case running(sessionID: String)
        case stopping(sessionID: String)
    }

    var onPresentationChanged: (@Sendable @MainActor (WatchCaptureOwnerPresentation) -> Void)?
    var onRelayDrainRequested: (@MainActor () -> Void)?
    var onPublishStatus: (@MainActor (WatchStatusContext) -> Void)?
    var onDiagnosticsEnvelopeRequested: (@MainActor (Date) -> Data?)?

    private let audioRecorder: any WatchAudioRecording
    private let audioSession: any WatchAudioSessionControlling
    private let locationProvider: any WatchLocationProviding
    private let storage: WatchCaptureStorage
    private let clock: any ObserverClock
    private let audioProbe: any WatchAudioProbing
    private let notificationScheduler: any WatchNotificationScheduling
    private let notificationCenter: NotificationCenter
    private let environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding
    private let sessionHistoryStore: WatchCaptureSessionHistoryStore
    private let lifecycleSerializer: WatchCaptureLifecycleSerializer

    private var activeSegment: ActiveSegment?
    private var openingSegment: ActiveSegment?
    /// The first manifest made it to disk. Its media must remain recoverable if
    /// opening the fully-persisted successor later fails.
    private var openingSegmentHasPersistedManifest = false
    private var rolloverPriorSegment: ActiveSegment?
    private var rolloverPriorAudioDuration: TimeInterval?
    private var segmentationTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var audioSessionIsActive = false
    private var audioArmed = false
    private var locationArmed = false
    private var lastKnownFix: WatchLocationFix?
    private var lastAudioCurrentTime: TimeInterval?
    private var status: WatchCaptureRuntimeStatus = .off
    private var statusSeq = 0
    private var currentSessionID: String?
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
    private var executingLifecycleIntent: WatchCaptureLifecycleSerializer.Intent?
    private var terminalClaimedSessionIDs: Set<String> = []

    init(
        audioRecorder: any WatchAudioRecording,
        audioSession: any WatchAudioSessionControlling,
        locationProvider: any WatchLocationProviding,
        storage: WatchCaptureStorage,
        clock: any ObserverClock = SystemObserverClock(),
        audioProbe: any WatchAudioProbing,
        notificationScheduler: any WatchNotificationScheduling,
        environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding = LiveWatchRelayDiagnosticsEnvironmentProvider(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.audioRecorder = audioRecorder
        self.audioSession = audioSession
        self.locationProvider = locationProvider
        self.storage = storage
        self.clock = clock
        self.audioProbe = audioProbe
        self.notificationScheduler = notificationScheduler
        self.environmentProvider = environmentProvider
        self.sessionHistoryStore = WatchCaptureSessionHistoryStore(storage: storage)
        self.notificationCenter = notificationCenter
        self.lifecycleSerializer = WatchCaptureLifecycleSerializer()

        self.audioRecorder.eventSink = self
        self.locationProvider.onFix = { [weak self] fix in
            self?.handleFix(fix)
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

    func refreshRelayCountsFromDisk() {
        let priorQueued = self.queuedCount
        let priorTransferring = self.transferringCount
        do {
            try self.refreshRelayCountsFromDiskThrowing()
            if self.queuedCount != priorQueued || self.transferringCount != priorTransferring {
                self.republishCurrentStatus()
            }
        } catch {
            watchCaptureLog.error("watch manifest scan failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .manifestScanFailed
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
        await self.lifecycleSerializer.settled()
    }

    private func reconcileOnLaunchInner(generation: Int) async {
        self.terminalReason = nil
        self.terminalDisposition = nil
        let reconciledSessionID = await self.reconcileSessionRecord(generation: generation)
        guard await self.continueLifecycleOperation(generation) else { return }
        do {
            let entries = try self.storage.scanManifests()
            for entry in entries {
                switch entry.manifest.state {
                case .captured, .persisted:
                    try self.recoverUnclean(entry, sessionID: reconciledSessionID)
                case .finalized:
                    var manifest = entry.manifest
                    manifest.state = .queued
                    try self.storage.writeManifest(manifest, in: entry.directoryURL)
                    self.queuedCount += 1
                case .queued, .transferring, .delivered, .acked, .safeToDelete:
                    break
                }
            }
            try self.refreshRelayCountsFromDiskThrowing()
        } catch {
            watchCaptureLog.error("watch reconcile scan failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .manifestScanFailed
        }
        self.republishCurrentStatus()
        self.notifyPresentationChanged()
        self.requestRelayDrain()
    }

    private func startInner(generation: Int) async {
        self.clearTransientStateForStart()
        guard self.mintSessionIdentity(startedAt: self.clock.now()) else {
            self.status = .needsAttention(.unavailable(reason: SourceVocabulary.watchStatusSaveFailed))
            self.notifyPresentationChanged()
            return
        }
        guard let currentSessionID else { return }
        let source = WatchCaptureSourceToken(sessionID: currentSessionID)
        self.status = .enrolling
        self.notifyPresentationChanged()
        guard await self.refreshWristAlertState(
            requestIfNotDetermined: true,
            generation: generation
        ) != nil else { return }

        guard await self.prepareAudioForOwnerStart(generation: generation) else {
            if self.isLifecycleGenerationCurrent(generation) {
                self.publishStatus(.idle)
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
            guard self.beginStatusSession(startedAt: startedAt) else {
                self.status = .needsAttention(.unavailable(reason: SourceVocabulary.watchStatusSaveFailed))
                self.notifyPresentationChanged()
                return
            }
            try self.openSegment(startedAt: startedAt, source: source)
            guard let segment = self.activeSegment else { return }
            if !segment.hasLiveSensor {
                self.refuseInitialStartAfterSegmentOpen(
                    error: .unavailable(reason: SourceVocabulary.watchMicrophoneUnavailable)
                )
                return
            }
            self.writeActiveSessionRecord(startedAt: startedAt)
            await self.replaceAudioTruthLease(verifiedAt: startedAt, generation: generation)
            guard await self.continueLifecycleOperation(generation) else { return }
            self.installAudioSessionObservers(source: source)
            self.status = self.statusForRunningSegment(segment)
            self.startSegmentationTask()
        } catch WatchCaptureEngineError.audioStartFailed {
            self.refuseInitialStartAfterSegmentOpen(
                error: WatchCaptureTerminalReason.audioStartFailed.observerError
            )
            return
        } catch {
            self.refuseInitialStartAfterSegmentOpen(
                error: WatchCaptureFailureMapper.observerError(for: error),
                persistenceFailed: self.openingSegmentHasPersistedManifest
            )
            return
        }
        if self.activeSegment != nil {
            self.publishStatus(.observing)
            self.startHeartbeatTask(source: source)
        } else {
            self.publishStatus(.idle)
        }
        self.notifyPresentationChanged()
    }

    private func stopInner() async {
        self.publishStatus(.stopping)
        await self.terminalize(
            reason: .ownerStopped,
            disposition: .ownerStopped,
            at: self.clock.now()
        )
    }

    func republishCurrentStatus() {
        let phase: WatchStatusContext.Phase = self.activeSegment == nil ? .idle : .observing
        self.publishStatus(phase)
    }

    private func admitLifecycleIntent(
        _ intent: WatchCaptureLifecycleSerializer.Intent
    ) -> WatchCaptureLifecycleSerializer.AdmissionDecision {
        if case .stop = intent, self.executingIntentCanBeSupersededByStop {
            self.lifecycleGeneration &+= 1
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
            await self.reconcileOnLaunchInner(generation: generation)
            guard self.isLifecycleGenerationCurrent(generation) else { return }
            if case .reconciling = self.lifecycleState {
                self.lifecycleState = .idle
            }

        case .start:
            guard case .idle = self.lifecycleState else { return }
            self.lifecycleState = .starting
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
            let source = WatchCaptureSourceToken(sessionID: sessionID)
            await self.rolloverInner(generation: generation, source: source)
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

    /// Once it has a session identity, a stale lifecycle continuation may only
    /// leave through terminalization. This keeps a superseded start from writing
    /// a refusal-shaped history row.
    private func continueLifecycleOperation(_ generation: Int) async -> Bool {
        guard !self.isLifecycleGenerationCurrent(generation) else { return true }
        guard self.currentSessionID != nil else {
            self.status = .off
            self.publishStatus(.idle)
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
    static let heartbeatIntervalSeconds = 15
    static let zeroAudioCurrentTimeObservationLimit = 3

    struct ActiveSegment {
        var directoryURL: URL
        var manifest: WatchSegmentManifest
        var audioURL: URL?
        var locationURL: URL?
        var locationLog: WatchCaptureLocationLog?
        var partialError: ObserverError?
        var hasElapsedLocationCoverage: Bool

        var hasLiveSensor: Bool {
            self.audioURL != nil || self.locationURL != nil
        }
    }

    func clearTransientStateForStart() {
        self.currentSessionID = nil
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
            self.refuseStart(.microphonePermissionDenied, error: .permissionDenied, settingsRoute: .microphone)
            return false
        case .notDetermined:
            let requested = await self.audioRecorder.requestPermission()
            guard await self.continueLifecycleOperation(generation) else { return false }
            guard requested == .granted else {
                self.refuseStart(.microphonePermissionNotDetermined, error: .permissionDenied, settingsRoute: .microphone)
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
            self.refuseStart(.audioArmFailed, error: WatchCaptureFailureMapper.observerError(for: error))
            return false
        }
    }

    func refuseStart(
        _ reason: WatchCaptureStartRefusalReason,
        error: ObserverError,
        settingsRoute: WatchCaptureSettingsRoute? = nil
    ) {
        let sessionID = self.currentSessionID
        let startedAt = self.sessionStartedAt
        self.startRefusalReason = reason
        self.settingsRoute = settingsRoute
        self.status = .needsAttention(error)
        self.currentSessionID = nil
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
            self.upsertSessionHistory(
                sessionID: sessionID,
                startedAt: startedAt,
                terminalAt: nil,
                noticeOwed: false,
                liveness: nil,
                environment: nil
            )
        }
    }

    /// Start-time setup never became a live session. Shut down any recorder the
    /// failed open may have touched, retain non-empty owner media, then preserve
    /// the established refusal-shaped lifecycle fact.
    func refuseInitialStartAfterSegmentOpen(
        error: ObserverError,
        persistenceFailed: Bool = false
    ) {
        let segment = self.activeSegment ?? self.openingSegment
        self.activeSegment = nil
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
        if self.audioArmed, segment?.audioURL != nil {
            _ = try? self.audioRecorder.stop()
        }
        if let segment {
            _ = self.removeSegmentDirectoryIfMediaIsProvablyEmpty(segment.directoryURL)
        }
        self.removeAudioTruthLease()
        if persistenceFailed {
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        self.refuseStart(.audioArmFailed, error: error)
        self.publishStatus(.idle)
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

    func openSegment(startedAt: Date, source: WatchCaptureSourceToken) throws {
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
        let day = self.storage.dayString(for: startedAt)
        let segmentKey = self.storage.provisionalSegmentString(for: startedAt)
        let directory = try self.storage.ensureSegmentDirectory(day: day, segment: segmentKey)
        var manifest = WatchSegmentManifest(
            id: UUID(),
            day: day,
            segment: segmentKey,
            startedAt: startedAt,
            duration: 0,
            sensors: [],
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
            locationLog: nil,
            partialError: nil,
            hasElapsedLocationCoverage: false
        )
        self.openingSegment = active
        try self.storage.writeManifest(manifest, in: directory)
        self.openingSegmentHasPersistedManifest = true

        if self.audioArmed {
            let audioURL = self.storage.audioURL(directory: directory)
            active.audioURL = audioURL
            manifest.sensors.append(.audio)
            active.manifest = manifest
            self.openingSegment = active
            do {
                try self.audioRecorder.start(url: audioURL, source: source)
                self.lastAudioCurrentTime = self.audioRecorder.currentTime
                self.zeroAudioCurrentTimeObservationCount = 0
            } catch {
                watchCaptureLog.error("watch audio start failed: \(String(describing: error), privacy: .public)")
                throw WatchCaptureEngineError.audioStartFailed
            }
        }

        if self.locationArmed {
            let locationURL = self.storage.locationURL(directory: directory)
            do {
                let locationLog = WatchCaptureLocationLog(url: locationURL, fileWriter: self.storage.fileWriter)
                try locationLog.openProvisionalHeader()
                if let lastKnownFix {
                    try locationLog.append(lastKnownFix.carryForward(at: startedAt))
                }
                active.locationURL = locationURL
                active.locationLog = locationLog
                manifest.sensors.append(.location)
                self.openingSegment = active
            } catch {
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
            try self.storage.writeManifest(manifest, in: directory)
        } catch {
            var failedActive = active
            self.markPartial(&failedActive, error: WatchCaptureFailureMapper.observerError(for: error))
            self.openingSegment = failedActive
            throw error
        }
        self.activeSegment = active
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
    }

    func adoptOpeningFailureSegment(
        _ explicitSegment: ActiveSegment? = nil,
        removeIfEmpty: Bool = true
    ) {
        let segment = explicitSegment ?? self.openingSegment
        self.openingSegment = nil
        self.openingSegmentHasPersistedManifest = false
        self.activeSegment = nil
        guard let segment else { return }
        if removeIfEmpty, self.removeSegmentDirectoryIfMediaIsProvablyEmpty(segment.directoryURL) {
            return
        }
        self.activeSegment = segment
    }

    /// A directory is disposable only when every owner-media path is known empty.
    /// A size-query failure deliberately retains the directory for reconciliation.
    func removeSegmentDirectoryIfMediaIsProvablyEmpty(_ directory: URL) -> Bool {
        let mediaURLs = [
            self.storage.audioURL(directory: directory),
            self.storage.locationURL(directory: directory),
        ]
        for url in mediaURLs {
            do {
                guard try self.storage.fileWriter.fileSize(at: url) == 0 else { return false }
            } catch {
                return false
            }
        }
        do {
            try self.storage.fileWriter.removeItem(at: directory)
            return true
        } catch {
            return false
        }
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

    func rolloverInner(generation: Int, source: WatchCaptureSourceToken) async {
        guard var segment = self.activeSegment else { return }
        let end = self.clock.now()
        self.activeSegment = nil
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
            try self.openSegment(startedAt: end, source: source)
            guard let newSegment = self.activeSegment, newSegment.hasLiveSensor else {
                self.adoptOpeningFailureSegment(self.activeSegment)
                rolloverTerminalReason = self.reopenFailureTerminalReason()
                throw WatchCaptureEngineError.audioStartFailed
            }
            self.status = self.statusForRunningSegment(newSegment)
        } catch WatchCaptureEngineError.audioStartFailed {
            self.adoptOpeningFailureSegment(removeIfEmpty: false)
            rolloverTerminalReason = self.reopenFailureTerminalReason()
            discardEmptySuccessorAfterStop = true
        } catch {
            self.adoptOpeningFailureSegment(
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
        self.publishStatus(.observing)
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
        let prepared = self.prepareFinalization(
            segment: segment,
            audioDuration: audioDuration,
            end: end
        )
        if renewLease, let verifiedAt = prepared.verifiedAudioAt {
            await self.replaceAudioTruthLease(verifiedAt: verifiedAt, generation: generation)
            if let generation, !self.isLifecycleGenerationCurrent(generation) {
                return false
            }
        }
        self.persistFinalization(segment: prepared.segment, manifest: prepared.manifest)
        return true
    }

    func finalizeTerminalSegment(
        _ segment: ActiveSegment,
        audioDuration: TimeInterval?,
        end: Date
    ) {
        let prepared = self.prepareFinalization(
            segment: segment,
            audioDuration: audioDuration,
            end: end
        )
        self.persistFinalization(segment: prepared.segment, manifest: prepared.manifest)
    }

    func prepareFinalization(
        segment: ActiveSegment,
        audioDuration: TimeInterval?,
        end: Date
    ) -> (segment: ActiveSegment, manifest: WatchSegmentManifest, verifiedAudioAt: Date?) {
        var segment = segment
        var manifest = segment.manifest
        var duration = max(audioDuration ?? end.timeIntervalSince(manifest.startedAt), 0)
        manifest.duration = duration
        var verifiedAudioAt: Date?

        if manifest.sensors.contains(.audio), let audioURL = segment.audioURL {
            if let probedDuration = self.audioProbe.decodableDuration(at: audioURL), probedDuration > 0 {
                duration = probedDuration
                manifest.duration = probedDuration
                verifiedAudioAt = manifest.startedAt.addingTimeInterval(probedDuration)
            } else {
                manifest.partial = true
                manifest.lost = true
                manifest.failureReason = WatchCaptureTerminalReason.audioUndecodable.observerError.message
                try? self.storage.fileWriter.removeItem(at: audioURL)
            }
        }

        if let locationURL = segment.locationURL, manifest.sensors.contains(.location) {
            do {
                let stats = try WatchCaptureLocationLog.reconcile(
                    url: locationURL,
                    armed: true,
                    fileWriter: self.storage.fileWriter
                )
                manifest.fixCount = stats.fixCount
                manifest.gap = stats.gap
            } catch {
                self.markPartial(&segment, error: WatchCaptureFailureMapper.observerError(for: error))
                manifest.partial = true
                manifest.failureReason = segment.partialError?.message
            }
        } else {
            manifest.fixCount = 0
            manifest.gap = false
        }

        if let partialError = segment.partialError {
            manifest.partial = true
            manifest.failureReason = partialError.message
        }

        return (segment, manifest, verifiedAudioAt)
    }

    func persistFinalization(segment: ActiveSegment, manifest: WatchSegmentManifest) {
        let finalSegment = self.storage.segmentString(
            for: manifest.startedAt,
            durationSeconds: max(manifest.duration, 1)
        )
        var manifest = manifest
        do {
            let finalDirectory = try self.storage.moveSegmentDirectoryIfNeeded(
                currentURL: segment.directoryURL,
                day: manifest.day,
                currentSegment: manifest.segment,
                finalSegment: finalSegment
            )
            manifest.segment = finalSegment
            manifest.state = .finalized
            try self.storage.writeManifest(manifest, in: finalDirectory)
            manifest.state = .queued
            try self.storage.writeManifest(manifest, in: finalDirectory)
            if manifest.partial {
                watchCaptureLog.error(
                    "watch segment partial id=\(manifest.id.uuidString, privacy: .public) state=queued"
                )
            }
            self.queuedCount += 1
            self.incrementSegmentsProduced(sessionID: self.currentSessionID)
            self.requestRelayDrain()
        } catch {
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
        }
    }

    func recoverUnclean(_ entry: WatchCaptureStorage.ManifestEntry, sessionID: String?) throws {
        var manifest = entry.manifest
        manifest.partial = true

        if manifest.sensors.contains(.location) {
            let locationURL = self.storage.locationURL(directory: entry.directoryURL)
            let stats = try WatchCaptureLocationLog.reconcile(
                url: locationURL,
                armed: true,
                fileWriter: self.storage.fileWriter
            )
            manifest.fixCount = stats.fixCount
            manifest.gap = stats.gap
        }

        if manifest.sensors.contains(.audio) {
            let audioURL = self.storage.audioURL(directory: entry.directoryURL)
            if let duration = self.audioProbe.decodableDuration(at: audioURL), duration > 0 {
                manifest.duration = duration
            } else {
                manifest.lost = true
                try? self.storage.fileWriter.removeItem(at: audioURL)
                self.status = .needsAttention(.unavailable(reason: "audio unavailable after restart"))
            }
        }

        let finalSegment = self.storage.segmentString(
            for: manifest.startedAt,
            durationSeconds: max(manifest.duration, 1)
        )
        let finalDirectory = try self.storage.moveSegmentDirectoryIfNeeded(
            currentURL: entry.directoryURL,
            day: manifest.day,
            currentSegment: manifest.segment,
            finalSegment: finalSegment
        )
        manifest.segment = finalSegment
        manifest.state = .queued
        if manifest.lost {
            manifest.failureReason = "audio unavailable after restart"
        }
        try self.storage.writeManifest(manifest, in: finalDirectory)
        if manifest.lost {
            watchCaptureLog.info(
                "watch segment lost id=\(manifest.id.uuidString, privacy: .public) state=queued"
            )
        } else {
            watchCaptureLog.info(
                "watch segment recovered id=\(manifest.id.uuidString, privacy: .public) state=queued"
            )
        }
        self.queuedCount += 1
        self.incrementSegmentsProduced(sessionID: sessionID)
        self.requestRelayDrain()
    }

    func incrementSegmentsProduced(sessionID: String?) {
        guard let sessionID else { return }
        if var record = try? self.storage.readSessionRecord(), record.sessionID == sessionID {
            record.segmentsProduced += 1
            do {
                try self.storage.writeSessionRecord(record)
            } catch {
                watchCaptureLog.error("watch segment count write failed: \(String(describing: error), privacy: .public)")
                self.persistenceAdvisory = .sessionRecordWriteFailed
                return
            }
        }
        guard var entry = self.sessionHistoryStore.entry(sessionID: sessionID, asOf: self.clock.now()) else { return }
        if let record = try? self.storage.readSessionRecord(),
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
            try self.sessionHistoryStore.upsert(entry, asOf: self.clock.now())
        } catch {
            watchCaptureLog.error("watch segment history write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
    }

    func handleFix(_ fix: WatchLocationFix) {
        self.lastKnownFix = fix
        guard self.locationArmed else { return }
        guard var segment = self.activeSegment, let locationLog = segment.locationLog else { return }
        do {
            try locationLog.append(fix)
            segment.hasElapsedLocationCoverage = true
            self.activeSegment = segment
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
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self, source] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            Task { @MainActor [weak self, source] in
                self?.handleInterruption(type, source: source)
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self, source] _ in
            Task { @MainActor [weak self, source] in
                self?.handleRouteChange(source: source)
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: nil
        ) { [weak self, source] _ in
            Task { @MainActor [weak self, source] in
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
            Task { @MainActor [weak self, source] in
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

    func requestRelayDrain() {
        self.onRelayDrainRequested?()
    }

    @discardableResult
    func mintSessionIdentity(startedAt: Date) -> Bool {
        guard self.currentSessionID == nil, self.sessionStartedAt == nil else {
            return self.currentSessionID != nil && self.sessionStartedAt != nil
        }
        let sessionID = UUID().uuidString
        let incremented: WatchCaptureSessionHistoryCounter
        do {
            guard let counter = try self.sessionHistoryStore.incrementLifetimeCounter() else {
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
        guard self.upsertSessionHistory(
            sessionID: sessionID,
            startedAt: startedAt,
            terminalAt: nil,
            noticeOwed: false,
            liveness: nil,
            environment: nil
        ) else {
            do {
                try self.sessionHistoryStore.revertLifetimeCounterIncrement(incremented)
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
    func beginStatusSession(startedAt: Date) -> Bool {
        self.mintSessionIdentity(startedAt: startedAt)
    }

    func publishStatus(_ phase: WatchStatusContext.Phase) {
        self.statusSeq += 1
        let asOf = self.clock.now()
        if phase != .idle, self.currentSessionID == nil || self.sessionStartedAt == nil {
            self.beginStatusSession(startedAt: asOf)
        }
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
            diagnosticsEnvelope: self.onDiagnosticsEnvelopeRequested?(asOf)
        )
        self.onPublishStatus?(context)
    }

    func clearNoticeOwedAfterConfirmedSubmission(sessionID: String?) {
        guard let sessionID else { return }
        let asOf = self.clock.now()
        do {
            if var entry = self.sessionHistoryStore.entry(sessionID: sessionID, asOf: asOf) {
                entry.noticeOwed = false
                try self.sessionHistoryStore.upsert(entry, asOf: asOf)
            }
        } catch {
            watchCaptureLog.error("watch history notice clear failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        guard var record = try? self.storage.readSessionRecord(), record.sessionID == sessionID else { return }
        record.noticeOwed = false
        do {
            try self.storage.writeSessionRecord(record)
        } catch {
            watchCaptureLog.error("watch notice clear failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
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

    func upsertTerminalNoticeFacts(
        sessionID: String?,
        decision: WatchNoticeDecision,
        delivered: Bool,
        authorization: WatchNotificationAuthorizationStatus,
        alertSetting: WatchNotificationAlertSetting,
        settingsRoute: WatchCaptureSettingsRoute?
    ) {
        guard let sessionID,
              var entry = self.sessionHistoryStore.entry(sessionID: sessionID, asOf: self.clock.now()),
              entry.terminalAt != nil
        else { return }
        entry.noticeDecision = decision.historyRawValue
        entry.noticeDelivered = delivered
        entry.notificationAuthorizationStatus = authorization
        entry.notificationAlertSetting = alertSetting
        entry.wristAlertAssurance = watchWristAlertAssurance(
            authorization: authorization,
            alertSetting: alertSetting
        )
        if let settingsRoute {
            entry.settingsRoute = settingsRoute
        }
        do {
            try self.sessionHistoryStore.upsert(entry, asOf: self.clock.now())
        } catch {
            watchCaptureLog.error("watch terminal notice history write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
    }

    func upsertSessionHistory(
        record: WatchCaptureSessionRecord? = nil,
        sessionID: String? = nil,
        startedAt: Date? = nil,
        terminalAt: Date? = nil,
        noticeOwed: Bool? = nil,
        liveness: WatchCaptureLivenessEvidence?,
        environment: WatchRelayDiagnosticsEnvironmentSnapshot?
    ) -> Bool {
        let id = record?.sessionID ?? sessionID ?? self.currentSessionID
        let start = record?.startedAt ?? startedAt ?? self.sessionStartedAt
        guard let id, let start else { return false }
        let prior = self.sessionHistoryStore.entry(sessionID: id, asOf: self.clock.now())
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
            try self.sessionHistoryStore.upsert(entry, asOf: self.clock.now())
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

    func submitTerminalNotice(
        reason: WatchCaptureTerminalReason,
        disposition: WatchCaptureTerminalDisposition,
        sessionID: String?
    ) async {
        guard disposition != .ownerStopped,
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
            self.upsertTerminalNoticeFacts(
                sessionID: sessionID,
                decision: decision,
                delivered: delivered,
                authorization: authorization,
                alertSetting: alertSetting,
                settingsRoute: nil
            )
            if delivered {
                self.clearNoticeOwedAfterConfirmedSubmission(sessionID: sessionID)
            }
        case let .cannotSchedule(route):
            let resolvedRoute: WatchCaptureSettingsRoute = copy == .microphoneAccessNeeded ? .microphone : route
            if sessionID == self.currentSessionID {
                self.setSettingsRouteIfVacant(resolvedRoute)
            }
            self.upsertTerminalNoticeFacts(
                sessionID: sessionID,
                decision: decision,
                delivered: false,
                authorization: authorization,
                alertSetting: alertSetting,
                settingsRoute: resolvedRoute
            )
        case .cancelLease:
            self.removeAudioTruthLease()
            self.upsertTerminalNoticeFacts(
                sessionID: sessionID,
                decision: decision,
                delivered: false,
                authorization: authorization,
                alertSetting: alertSetting,
                settingsRoute: nil
            )
        case .none:
            self.upsertTerminalNoticeFacts(
                sessionID: sessionID,
                decision: decision,
                delivered: false,
                authorization: authorization,
                alertSetting: alertSetting,
                settingsRoute: nil
            )
            break
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
                self.publishStatus(.observing)
            }
        }
    }

    func cancelHeartbeatTask() {
        self.heartbeatTask?.cancel()
        self.heartbeatTask = nil
    }

    func writeActiveSessionRecord(startedAt: Date) {
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
            try self.storage.writeSessionRecord(record)
            self.upsertSessionHistory(record: record, liveness: nil, environment: nil)
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
    ) -> WatchCaptureSessionRecord? {
        self.terminalReason = reason
        self.terminalDisposition = disposition
        if reason == .microphonePermissionRevoked {
            self.setSettingsRouteIfVacant(.microphone)
        }
        guard let currentSessionID = sessionID ?? self.currentSessionID,
              let sessionStartedAt = startedAt ?? self.sessionStartedAt
        else { return nil }
        let priorRecord = try? self.storage.readSessionRecord()
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
            try self.storage.writeSessionRecord(record)
        } catch {
            watchCaptureLog.error("watch terminal session record write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        if !self.upsertSessionHistory(
            record: record,
            liveness: liveness,
            environment: environment
        ) {
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        return record
    }

    func repairTerminalHistoryIfNeeded(_ record: WatchCaptureSessionRecord) {
        guard record.state == .terminal,
              let terminalReason = record.terminalReason,
              let terminalDisposition = record.terminalDisposition,
              let terminalAt = record.terminalAt,
              var entry = self.sessionHistoryStore.entry(sessionID: record.sessionID, asOf: self.clock.now()),
              entry.terminalAt == nil
        else { return }

        entry.terminalReason = terminalReason
        entry.terminalDisposition = terminalDisposition
        entry.terminalAt = terminalAt
        entry.noticeOwed = record.noticeOwed
        do {
            try self.sessionHistoryStore.upsert(entry, asOf: self.clock.now())
        } catch {
            watchCaptureLog.error("watch terminal history repair failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
    }

    func reconcileSessionRecord(generation: Int) async -> String? {
        do {
            guard let record = try self.storage.readSessionRecord() else {
                return nil
            }
            self.currentSessionID = record.sessionID
            self.sessionStartedAt = record.startedAt
            switch record.state {
            case .active:
                if let history = self.sessionHistoryStore.entry(
                    sessionID: record.sessionID,
                    asOf: self.clock.now()
                ), let terminalAt = history.terminalAt {
                    let repaired = WatchCaptureSessionRecord(
                        sessionID: record.sessionID,
                        startedAt: record.startedAt,
                        state: .terminal,
                        terminalReason: history.terminalReason,
                        terminalDisposition: history.terminalDisposition,
                        terminalAt: terminalAt,
                        noticeOwed: history.noticeOwed
                    )
                    do {
                        try self.storage.writeSessionRecord(repaired)
                    } catch {
                        self.persistenceAdvisory = .sessionRecordWriteFailed
                    }
                    self.terminalReason = repaired.terminalReason
                    self.terminalDisposition = repaired.terminalDisposition
                    self.removeAudioTruthLease()
                    return record.sessionID
                }
                let terminalAt = self.clock.now()
                self.status = .needsAttention(WatchCaptureTerminalReason.processExitedWhileActive.observerError(disposition: .inferredStoppedItself))
                self.removeAudioTruthLease()
                self.terminalClaimedSessionIDs.insert(record.sessionID)
                _ = self.persistTerminalFact(
                    reason: .processExitedWhileActive,
                    disposition: .inferredStoppedItself,
                    at: terminalAt,
                    sessionID: record.sessionID,
                    startedAt: record.startedAt
                )
                await self.submitTerminalNotice(
                    reason: .processExitedWhileActive,
                    disposition: .inferredStoppedItself,
                    sessionID: record.sessionID
                )
                guard self.isLifecycleGenerationCurrent(generation) else { return nil }
            case .terminal:
                self.removeAudioTruthLease()
                self.repairTerminalHistoryIfNeeded(record)
                if record.terminalDisposition == .ownerStopped {
                    self.terminalReason = record.terminalReason
                    self.terminalDisposition = record.terminalDisposition
                } else if record.noticeOwed {
                    let reason = record.terminalReason ?? .processExitedWhileActive
                    let disposition = record.terminalDisposition ?? .inferredStoppedItself
                    self.terminalReason = record.terminalReason
                    self.terminalDisposition = record.terminalDisposition
                    self.status = .needsAttention(
                        reason.observerError(disposition: disposition)
                    )
                    await self.submitTerminalNotice(
                        reason: reason,
                        disposition: disposition,
                        sessionID: record.sessionID
                    )
                    guard self.isLifecycleGenerationCurrent(generation) else { return nil }
                }
            }
            return record.sessionID
        } catch {
            watchCaptureLog.error("watch session record unreadable: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordUnreadable
            self.terminalReason = .processExitedWhileActive
            self.terminalDisposition = .inferredStoppedItself
            self.status = .needsAttention(WatchCaptureTerminalReason.processExitedWhileActive.observerError(disposition: .inferredStoppedItself))
            self.removeAudioTruthLease()
            let now = self.clock.now()
            guard self.mintSessionIdentity(startedAt: now),
                  let currentSessionID,
                  let sessionStartedAt
            else { return nil }
            self.terminalClaimedSessionIDs.insert(currentSessionID)
            _ = self.persistTerminalFact(
                reason: .processExitedWhileActive,
                disposition: .inferredStoppedItself,
                at: now,
                sessionID: currentSessionID,
                startedAt: sessionStartedAt
            )
            await self.submitTerminalNotice(
                reason: .processExitedWhileActive,
                disposition: .inferredStoppedItself,
                sessionID: currentSessionID
            )
            guard self.isLifecycleGenerationCurrent(generation) else { return nil }
            return currentSessionID
        }
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
           self.removeSegmentDirectoryIfMediaIsProvablyEmpty(activeSegment.directoryURL) {
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
        self.publishStatus(.idle)
        self.notifyPresentationChanged()

        let record = self.persistTerminalFact(
            reason: reason,
            disposition: disposition,
            at: date,
            liveness: liveness,
            sessionID: sessionID,
            startedAt: self.sessionStartedAt
        )
        self.notifyPresentationChanged()

        if let segment {
            self.finalizeTerminalSegment(segment, audioDuration: audioDuration, end: date)
        }
        if let rolloverSegment {
            self.finalizeTerminalSegment(
                rolloverSegment,
                audioDuration: rolloverAudioDuration,
                end: date
            )
        }
        self.notifyPresentationChanged()
        await self.submitTerminalNotice(
            reason: reason,
            disposition: disposition,
            sessionID: record?.sessionID ?? sessionID
        )
    }

    func refreshRelayCountsFromDiskThrowing() throws {
        let entries = try self.storage.scanManifests()
        self.queuedCount = entries.filter { $0.manifest.state == .queued }.count
        self.transferringCount = entries.filter { $0.manifest.state == .transferring }.count
        self.confirmingCount = entries.filter { $0.manifest.state == .delivered }.count
        self.handedOffCount = entries.filter {
            $0.manifest.state == .acked || $0.manifest.state == .safeToDelete
        }.count
    }
}
