// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

private let watchCaptureLog = Logger(subsystem: "app.solstone.swift", category: "watch-capture")

@MainActor
final class WatchCaptureEngine {
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

    private var activeSegment: ActiveSegment?
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
    private var noticeRecordToClear: WatchCaptureSessionRecord?
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
    private var terminalNoticeDecision: String?
    private var terminalNoticeDelivered: Bool?

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

    func reconcileOnLaunch() async {
        self.terminalReason = nil
        self.terminalDisposition = nil
        self.noticeRecordToClear = nil
        await self.reconcileSessionRecord()
        do {
            let entries = try self.storage.scanManifests()
            for entry in entries {
                switch entry.manifest.state {
                case .captured, .persisted:
                    try self.recoverUnclean(entry)
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

    func start() async {
        guard self.activeSegment == nil else { return }
        self.clearTransientStateForStart()
        self.mintSessionIdentity(startedAt: self.clock.now())
        self.status = .enrolling
        self.notifyPresentationChanged()
        await self.refreshWristAlertState(requestIfNotDetermined: true)

        guard await self.prepareAudioForOwnerStart() else {
            self.publishStatus(.idle)
            self.notifyPresentationChanged()
            return
        }

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
            self.beginStatusSession(startedAt: startedAt)
            try self.openSegment(startedAt: startedAt)
            guard let segment = self.activeSegment else {
                self.refuseStart(.audioArmFailed, error: .unavailable(reason: SourceVocabulary.watchMicrophoneUnavailable))
                self.publishStatus(.idle)
                self.notifyPresentationChanged()
                return
            }
            if !segment.hasLiveSensor {
                self.refuseStart(.audioArmFailed, error: self.errorForNonRunningSegment(segment))
                self.activeSegment = nil
                try? self.storage.fileWriter.removeItem(at: segment.directoryURL)
                self.publishStatus(.idle)
                self.notifyPresentationChanged()
                return
            }
            self.writeActiveSessionRecord(startedAt: startedAt)
            await self.replaceAudioTruthLease(verifiedAt: startedAt)
            self.installAudioSessionObservers()
            self.status = self.statusForRunningSegment(segment)
            self.startSegmentationTask()
        } catch WatchCaptureEngineError.audioStartFailed {
            let observerError = WatchCaptureTerminalReason.audioStartFailed.observerError
            self.refuseStart(.audioArmFailed, error: observerError)
            if let segment = self.activeSegment {
                self.activeSegment = nil
                try? self.storage.fileWriter.removeItem(at: segment.directoryURL)
            }
        } catch {
            let observerError = WatchCaptureFailureMapper.observerError(for: error)
            self.refuseStart(.audioArmFailed, error: observerError)
            if let segment = self.activeSegment {
                self.activeSegment = nil
                try? self.storage.fileWriter.removeItem(at: segment.directoryURL)
            }
        }
        if self.activeSegment != nil {
            self.publishStatus(.observing)
            self.startHeartbeatTask()
        } else {
            self.publishStatus(.idle)
        }
        self.notifyPresentationChanged()
    }

    func stop() async {
        if self.activeSegment != nil {
            self.publishStatus(.stopping)
        }
        await self.terminateCurrentSession(
            reason: .ownerStopped,
            disposition: .ownerStopped,
            at: self.clock.now()
        )
    }

    func republishCurrentStatus() {
        let phase: WatchStatusContext.Phase = self.activeSegment == nil ? .idle : .observing
        self.publishStatus(phase)
    }
}

private enum WatchCaptureEngineError: Error {
    case audioStartFailed
}

extension WatchCaptureEngine: WatchAudioRecorderEventSink {
    func audioRecorderDidFinish(successfully: Bool) {
        guard !successfully else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.terminateCurrentSession(
                reason: .audioFinishUnsuccessful,
                disposition: .detectedStoppedItself,
                at: self.clock.now()
            )
        }
    }

    func audioRecorderEncodeError(_ error: (any Error)?) {
        if let error {
            watchCaptureLog.error("watch audio encode failed: \(String(describing: error), privacy: .public)")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.terminateCurrentSession(
                reason: .audioEncodeError,
                disposition: .detectedStoppedItself,
                at: self.clock.now()
            )
        }
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
        self.noticeRecordToClear = nil
        self.persistenceAdvisory = nil
        self.terminalEnvironmentSnapshot = nil
        self.terminalNoticeDecision = nil
        self.terminalNoticeDelivered = nil
        self.lastAudioCurrentTime = nil
        self.zeroAudioCurrentTimeObservationCount = 0
    }

    func prepareAudioForOwnerStart() async -> Bool {
        switch self.audioRecorder.microphonePermission {
        case .granted:
            break
        case .denied:
            self.refuseStart(.microphonePermissionDenied, error: .permissionDenied, settingsRoute: .microphone)
            return false
        case .notDetermined:
            let requested = await self.audioRecorder.requestPermission()
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

    func openSegment(startedAt: Date) throws {
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
        try self.storage.writeManifest(manifest, in: directory)

        var active = ActiveSegment(
            directoryURL: directory,
            manifest: manifest,
            audioURL: nil,
            locationURL: nil,
            locationLog: nil,
            partialError: nil,
            hasElapsedLocationCoverage: false
        )

        if self.audioArmed {
            let audioURL = self.storage.audioURL(directory: directory)
            do {
                try self.audioRecorder.start(url: audioURL)
                active.audioURL = audioURL
                manifest.sensors.append(.audio)
                self.lastAudioCurrentTime = self.audioRecorder.currentTime
                self.zeroAudioCurrentTimeObservationCount = 0
            } catch {
                self.audioArmed = false
                self.activeSegment = active
                watchCaptureLog.error("watch audio start failed: \(String(describing: error), privacy: .public)")
                try? self.storage.fileWriter.removeItem(at: directory)
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
            } catch {
                self.locationArmed = false
                self.locationProvider.stop()
                self.markPartial(&active, error: WatchCaptureFailureMapper.observerError(for: error))
            }
        }

        manifest.partial = active.partialError != nil
        manifest.failureReason = active.partialError?.message
        manifest.state = .persisted
        active.manifest = manifest
        self.activeSegment = active
        do {
            try self.storage.writeManifest(manifest, in: directory)
        } catch {
            var failedActive = active
            self.markPartial(&failedActive, error: WatchCaptureFailureMapper.observerError(for: error))
            self.activeSegment = failedActive
            throw error
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
                await self.rollover()
            }
        }
    }

    func rollover() async {
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

        var rolloverTerminalReason: WatchCaptureTerminalReason?
        do {
            try self.openSegment(startedAt: end)
            if let newSegment = self.activeSegment {
                if newSegment.hasLiveSensor {
                    self.status = self.statusForRunningSegment(newSegment)
                } else {
                    self.status = .needsAttention(self.errorForNonRunningSegment(newSegment))
                    self.activeSegment = nil
                    try? self.storage.fileWriter.removeItem(at: newSegment.directoryURL)
                    rolloverTerminalReason = self.reopenFailureTerminalReason()
                }
            }
        } catch WatchCaptureEngineError.audioStartFailed {
            self.activeSegment = nil
            rolloverTerminalReason = self.reopenFailureTerminalReason()
        } catch {
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
        }

        if let newSegment = self.activeSegment, !newSegment.hasLiveSensor {
            self.status = .needsAttention(self.errorForNonRunningSegment(newSegment))
            self.activeSegment = nil
            try? self.storage.fileWriter.removeItem(at: newSegment.directoryURL)
            rolloverTerminalReason = self.reopenFailureTerminalReason()
        }

        if let rolloverTerminalReason {
            await self.recordTerminalFact(reason: rolloverTerminalReason, disposition: .detectedStoppedItself, at: end)
            self.segmentationTask?.cancel()
            self.segmentationTask = nil
            self.cancelHeartbeatTask()
            self.locationArmed = false
            self.locationProvider.stop()
            self.audioArmed = false
            self.removeAudioSessionObservers()
            if self.audioSessionIsActive {
                try? self.audioSession.setActive(false, options: [])
                self.audioSessionIsActive = false
            }
            await self.finalize(segment: segment, audioDuration: audioDuration, end: end, renewLease: false)
            self.status = .needsAttention(
                rolloverTerminalReason.observerError(disposition: .detectedStoppedItself)
            )
            self.lastAudioCurrentTime = nil
            self.zeroAudioCurrentTimeObservationCount = 0
            self.publishStatus(.idle)
        } else {
            if self.activeSegment == nil {
                self.segmentationTask?.cancel()
                self.segmentationTask = nil
                self.cancelHeartbeatTask()
                self.locationArmed = false
                self.locationProvider.stop()
                self.audioArmed = false
            }

            await self.finalize(segment: segment, audioDuration: audioDuration, end: end)
            if self.activeSegment == nil {
                self.publishStatus(.idle)
            } else {
                self.publishStatus(.observing)
            }
        }
        self.notifyPresentationChanged()
    }

    func finalize(
        segment: ActiveSegment,
        audioDuration: TimeInterval?,
        end: Date,
        renewLease: Bool = true
    ) async {
        var segment = segment
        var manifest = segment.manifest
        var duration = max(audioDuration ?? end.timeIntervalSince(manifest.startedAt), 0)
        manifest.duration = duration

        if manifest.sensors.contains(.audio), let audioURL = segment.audioURL {
            if let probedDuration = self.audioProbe.decodableDuration(at: audioURL), probedDuration > 0 {
                duration = probedDuration
                manifest.duration = probedDuration
                if renewLease {
                    await self.replaceAudioTruthLease(
                        verifiedAt: manifest.startedAt.addingTimeInterval(probedDuration)
                    )
                }
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

        let finalSegment = self.storage.segmentString(for: manifest.startedAt, durationSeconds: max(duration, 1))
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
            if var record = try? self.storage.readSessionRecord() {
                record.segmentsProduced += 1
                try self.storage.writeSessionRecord(record)
                self.upsertSessionHistory(record: record, liveness: nil, environment: nil)
            }
            self.requestRelayDrain()
        } catch {
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
        }
    }

    func recoverUnclean(_ entry: WatchCaptureStorage.ManifestEntry) throws {
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
        self.requestRelayDrain()
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

    func errorForNonRunningSegment(_ segment: ActiveSegment) -> ObserverError {
        segment.partialError ?? .unavailable(reason: "no sensors available")
    }

    func installAudioSessionObservers() {
        self.removeAudioSessionObservers()
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            Task { @MainActor [weak self] in
                self?.handleInterruption(type)
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleRouteChange()
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.terminateCurrentSession(
                    reason: .audioMediaServicesLost,
                    disposition: .detectedStoppedItself,
                    at: self?.clock.now() ?? Date()
                )
            }
        })
        self.audioSessionObservers.append(self.notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.terminateCurrentSession(
                    reason: .audioMediaServicesReset,
                    disposition: .detectedStoppedItself,
                    at: self?.clock.now() ?? Date()
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

    func handleInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.terminateCurrentSession(
                    reason: .audioInterrupted,
                    disposition: .detectedStoppedItself,
                    at: self.clock.now()
                )
            }
        case .ended:
            break
        @unknown default:
            break
        }
    }

    func handleRouteChange() async {
        guard self.activeSegment != nil, !self.audioSession.hasSuitableInput else { return }
        await self.terminateCurrentSession(
            reason: .audioRouteUnavailable,
            disposition: .detectedStoppedItself,
            at: self.clock.now()
        )
    }

    func notifyPresentationChanged() {
        self.onPresentationChanged?(self.ownerPresentation)
    }

    func requestRelayDrain() {
        self.onRelayDrainRequested?()
    }

    func mintSessionIdentity(startedAt: Date) {
        guard self.currentSessionID == nil || self.sessionStartedAt == nil else { return }
        self.currentSessionID = UUID().uuidString
        self.sessionStartedAt = startedAt
        do {
            guard try self.sessionHistoryStore.incrementLifetimeCounter() != nil else {
                watchCaptureLog.error("watch session counter unreadable")
                return
            }
        } catch {
            watchCaptureLog.error("watch session counter write failed: \(String(describing: error), privacy: .public)")
        }
    }

    func beginStatusSession(startedAt: Date) {
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

    func clearNoticeOwedAfterConfirmedSubmission() {
        guard let owedRecord = self.noticeRecordToClear,
              var record = try? self.storage.readSessionRecord(),
              record.sessionID == owedRecord.sessionID
        else { return }
        record.noticeOwed = false
        do {
            try self.storage.writeSessionRecord(record)
            self.upsertSessionHistory(record: record, liveness: nil, environment: nil)
            self.noticeRecordToClear = nil
        } catch {
            watchCaptureLog.error("watch notice clear failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
    }

    @discardableResult
    func refreshWristAlertState(
        requestIfNotDetermined: Bool
    ) async -> (WatchNotificationAuthorizationStatus, WatchNotificationAlertSetting) {
        var authorization = await self.notificationScheduler.authorizationStatus()
        if authorization == .notDetermined, requestIfNotDetermined {
            do {
                authorization = try await self.notificationScheduler.requestAuthorization()
            } catch {
                watchCaptureLog.error("watch notification authorization failed: \(String(describing: error), privacy: .public)")
            }
        }
        let alertSetting = await self.notificationScheduler.alertSetting()
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

    func upsertTerminalNoticeFacts(decision: WatchNoticeDecision, delivered: Bool) {
        self.terminalNoticeDecision = decision.historyRawValue
        self.terminalNoticeDelivered = delivered
        guard let record = try? self.storage.readSessionRecord(), record.state == .terminal else { return }
        self.upsertSessionHistory(record: record, liveness: nil, environment: nil)
    }

    func upsertSessionHistory(
        record: WatchCaptureSessionRecord? = nil,
        sessionID: String? = nil,
        startedAt: Date? = nil,
        terminalAt: Date? = nil,
        noticeOwed: Bool? = nil,
        liveness: WatchCaptureLivenessEvidence?,
        environment: WatchRelayDiagnosticsEnvironmentSnapshot?
    ) {
        let id = record?.sessionID ?? sessionID ?? self.currentSessionID
        let start = record?.startedAt ?? startedAt ?? self.sessionStartedAt
        guard let id, let start else { return }
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
            noticeDecision: self.terminalNoticeDecision ?? prior?.noticeDecision,
            noticeDelivered: self.terminalNoticeDelivered ?? prior?.noticeDelivered,
            notificationAuthorizationStatus: self.notificationAuthorizationStatus ?? prior?.notificationAuthorizationStatus,
            notificationAlertSetting: self.notificationAlertSetting ?? prior?.notificationAlertSetting,
            wristAlertAssurance: self.wristAlertAssurance ?? prior?.wristAlertAssurance,
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
        } catch {
            watchCaptureLog.error("watch session history write failed: \(String(describing: error), privacy: .public)")
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

    func replaceAudioTruthLease(verifiedAt: Date) async {
        self.lastVerifiedAudioAt = verifiedAt
        let (authorization, alertSetting) = await self.refreshWristAlertState(requestIfNotDetermined: false)
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
                self.leaseIsArmed = true
            } else {
                self.removeAudioTruthLease()
            }
        case let .cannotSchedule(route):
            self.removeAudioTruthLease()
            self.setSettingsRouteIfVacant(route)
        case .cancelLease, .none:
            self.removeAudioTruthLease()
        }
    }

    func submitTerminalNotice(reason: WatchCaptureTerminalReason, disposition: WatchCaptureTerminalDisposition) async {
        guard disposition != .ownerStopped,
              let copy = WatchNoticeCopy(reason: reason, disposition: disposition)
        else { return }

        let (authorization, alertSetting) = await self.refreshWristAlertState(requestIfNotDetermined: false)
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
            self.upsertTerminalNoticeFacts(decision: decision, delivered: delivered)
            if delivered {
                self.clearNoticeOwedAfterConfirmedSubmission()
            }
        case let .cannotSchedule(route):
            if copy == .microphoneAccessNeeded {
                self.setSettingsRouteIfVacant(.microphone)
            } else {
                self.setSettingsRouteIfVacant(route)
            }
            self.upsertTerminalNoticeFacts(decision: decision, delivered: false)
        case .cancelLease:
            self.removeAudioTruthLease()
            self.upsertTerminalNoticeFacts(decision: decision, delivered: false)
        case .none:
            self.upsertTerminalNoticeFacts(decision: decision, delivered: false)
            break
        }
    }

    func startHeartbeatTask() {
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
                guard await self.evaluateAudioLiveness() else { return }
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

    func recordTerminalFact(
        reason: WatchCaptureTerminalReason,
        disposition: WatchCaptureTerminalDisposition,
        at date: Date,
        liveness: WatchCaptureLivenessEvidence? = nil
    ) async {
        self.terminalReason = reason
        self.terminalDisposition = disposition
        if reason == .microphonePermissionRevoked {
            self.setSettingsRouteIfVacant(.microphone)
        }
        self.removeAudioTruthLease()
        guard let currentSessionID, let sessionStartedAt else {
            await self.submitTerminalNotice(reason: reason, disposition: disposition)
            return
        }
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
        do {
            try self.storage.writeSessionRecord(record)
            let environment = self.environmentProvider.snapshot()
            self.terminalEnvironmentSnapshot = environment
            self.upsertSessionHistory(
                record: record,
                liveness: liveness,
                environment: environment
            )
            if record.noticeOwed {
                self.noticeRecordToClear = record
            }
        } catch {
            watchCaptureLog.error("watch terminal session record write failed: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordWriteFailed
        }
        await self.submitTerminalNotice(reason: reason, disposition: disposition)
    }

    func reconcileSessionRecord() async {
        do {
            guard var record = try self.storage.readSessionRecord() else {
                return
            }
            self.currentSessionID = record.sessionID
            self.sessionStartedAt = record.startedAt
            switch record.state {
            case .active:
                let terminalAt = self.clock.now()
                self.terminalReason = .processExitedWhileActive
                self.terminalDisposition = .inferredStoppedItself
                self.status = .needsAttention(WatchCaptureTerminalReason.processExitedWhileActive.observerError(disposition: .inferredStoppedItself))
                self.removeAudioTruthLease()
                record.state = .terminal
                record.terminalReason = .processExitedWhileActive
                record.terminalDisposition = .inferredStoppedItself
                record.terminalAt = terminalAt
                record.noticeOwed = true
                do {
                    try self.storage.writeSessionRecord(record)
                    let environment = self.environmentProvider.snapshot()
                    self.terminalEnvironmentSnapshot = environment
                    self.upsertSessionHistory(
                        record: record,
                        liveness: nil,
                        environment: environment
                    )
                    self.noticeRecordToClear = record
                } catch {
                    watchCaptureLog.error("watch terminal session record write failed: \(String(describing: error), privacy: .public)")
                    self.persistenceAdvisory = .sessionRecordWriteFailed
                }
                await self.submitTerminalNotice(
                    reason: .processExitedWhileActive,
                    disposition: .inferredStoppedItself
                )
            case .terminal:
                self.removeAudioTruthLease()
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
                    self.noticeRecordToClear = record
                    await self.submitTerminalNotice(reason: reason, disposition: disposition)
                }
            }
        } catch {
            watchCaptureLog.error("watch session record unreadable: \(String(describing: error), privacy: .public)")
            self.persistenceAdvisory = .sessionRecordUnreadable
            self.terminalReason = .processExitedWhileActive
            self.terminalDisposition = .inferredStoppedItself
            self.status = .needsAttention(WatchCaptureTerminalReason.processExitedWhileActive.observerError(disposition: .inferredStoppedItself))
            self.removeAudioTruthLease()
            let now = self.clock.now()
            self.mintSessionIdentity(startedAt: now)
            let record = WatchCaptureSessionRecord(
                sessionID: self.currentSessionID ?? UUID().uuidString,
                startedAt: self.sessionStartedAt ?? now,
                state: .terminal,
                terminalReason: .processExitedWhileActive,
                terminalDisposition: .inferredStoppedItself,
                terminalAt: now,
                noticeOwed: true
            )
            do {
                try self.storage.writeSessionRecord(record)
                let environment = self.environmentProvider.snapshot()
                self.terminalEnvironmentSnapshot = environment
                self.upsertSessionHistory(
                    record: record,
                    liveness: nil,
                    environment: environment
                )
                self.noticeRecordToClear = record
            } catch {
                watchCaptureLog.error("watch terminal session record write failed: \(String(describing: error), privacy: .public)")
                self.persistenceAdvisory = .sessionRecordWriteFailed
            }
            await self.submitTerminalNotice(
                reason: .processExitedWhileActive,
                disposition: .inferredStoppedItself
            )
        }
    }

    func evaluateAudioLiveness() async -> Bool {
        guard self.activeSegment != nil, self.audioArmed else {
            self.zeroAudioCurrentTimeObservationCount = 0
            self.lastAudioCurrentTime = nil
            return true
        }
        guard self.audioRecorder.isRecording else {
            let liveness = WatchCaptureLivenessEvidence(
                previousAudioCurrentTime: self.lastAudioCurrentTime,
                audioCurrentTime: nil,
                zeroAudioCurrentTimeObservationCount: self.zeroAudioCurrentTimeObservationCount
            )
            self.zeroAudioCurrentTimeObservationCount = 0
            await self.terminateCurrentSession(
                reason: .audioRecorderStopped,
                disposition: .detectedStoppedItself,
                at: self.clock.now(),
                liveness: liveness
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
            previousAudioCurrentTime: lastAudioCurrentTime,
            audioCurrentTime: currentTime,
            zeroAudioCurrentTimeObservationCount: self.zeroAudioCurrentTimeObservationCount
        )
        self.zeroAudioCurrentTimeObservationCount = 0
        await self.terminateCurrentSession(
            reason: .audioClockStalled,
            disposition: .detectedStoppedItself,
            at: self.clock.now(),
            liveness: liveness
        )
        return false
    }

    func terminateCurrentSession(
        reason: WatchCaptureTerminalReason,
        disposition: WatchCaptureTerminalDisposition,
        at date: Date,
        liveness: WatchCaptureLivenessEvidence? = nil
    ) async {
        guard self.activeSegment != nil || self.audioArmed || self.locationArmed else { return }
        await self.recordTerminalFact(reason: reason, disposition: disposition, at: date, liveness: liveness)
        self.cancelHeartbeatTask()
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.removeAudioSessionObservers()
        self.locationProvider.stop()

        var segment = self.activeSegment
        self.activeSegment = nil
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

        self.audioArmed = false
        self.locationArmed = false
        self.lastAudioCurrentTime = nil
        self.zeroAudioCurrentTimeObservationCount = 0
        if self.audioSessionIsActive {
            try? self.audioSession.setActive(false, options: [])
            self.audioSessionIsActive = false
        }

        if let segment {
            await self.finalize(segment: segment, audioDuration: audioDuration, end: date, renewLease: false)
        }

        switch disposition {
        case .ownerStopped:
            self.status = .off
        case .detectedStoppedItself, .inferredStoppedItself:
            self.status = .needsAttention(reason.observerError(disposition: disposition))
        }
        self.publishStatus(.idle)
        self.notifyPresentationChanged()
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
