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

    private let audioRecorder: any WatchAudioRecording
    private let audioSession: any WatchAudioSessionControlling
    private let locationProvider: any WatchLocationProviding
    private let storage: WatchCaptureStorage
    private let clock: any ObserverClock
    private let audioProbe: any WatchAudioProbing
    private let notificationCenter: NotificationCenter

    private var activeSegment: ActiveSegment?
    private var segmentationTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionIsActive = false
    private var audioArmed = false
    private var locationArmed = false
    private var lastKnownFix: WatchLocationFix?
    private var status: WatchCaptureRuntimeStatus = .off
    private var runtimeAttention: ObserverError?
    private var queuedCount = 0
    private var transferringCount = 0
    private var handedOffCount = 0

    init(
        audioRecorder: any WatchAudioRecording,
        audioSession: any WatchAudioSessionControlling,
        locationProvider: any WatchLocationProviding,
        storage: WatchCaptureStorage,
        clock: any ObserverClock = SystemObserverClock(),
        audioProbe: any WatchAudioProbing,
        notificationCenter: NotificationCenter = .default
    ) {
        self.audioRecorder = audioRecorder
        self.audioSession = audioSession
        self.locationProvider = locationProvider
        self.storage = storage
        self.clock = clock
        self.audioProbe = audioProbe
        self.notificationCenter = notificationCenter

        self.locationProvider.onFix = { [weak self] fix in
            self?.handleFix(fix)
        }
        self.locationProvider.onAuthorizationChanged = { [weak self] authorization in
            self?.handleAuthorizationChanged(authorization)
        }
    }

    var ownerPresentation: WatchCaptureOwnerPresentation {
        WatchCaptureOwnerPresentation(
            status: self.status,
            queuedCount: self.queuedCount,
            transferringCount: self.transferringCount,
            handedOffCount: self.handedOffCount,
            isSessionRunning: self.activeSegment != nil
        )
    }

    func refreshRelayCountsFromDisk() {
        do {
            try self.refreshRelayCountsFromDiskThrowing()
        } catch {
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
        }
        self.notifyPresentationChanged()
    }

    func reconcileOnLaunch() async {
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
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
        }
        self.notifyPresentationChanged()
        self.requestRelayDrain()
    }

    func start() async {
        guard self.activeSegment == nil else { return }
        self.runtimeAttention = nil
        self.status = .enrolling
        self.notifyPresentationChanged()

        self.audioArmed = await self.armAudio()
        self.locationArmed = self.armLocation()
        if self.locationArmed {
            do {
                try self.locationProvider.start()
            } catch {
                self.locationArmed = false
                self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
            }
        }

        guard self.audioArmed || self.locationArmed else {
            if case .needsAttention = self.status {
                self.notifyPresentationChanged()
                return
            }
            self.status = .needsAttention(.permissionDenied)
            self.notifyPresentationChanged()
            return
        }

        do {
            try self.openSegment(startedAt: self.clock.now())
            guard let segment = self.activeSegment else {
                self.status = .needsAttention(.unavailable(reason: "no sensors available"))
                self.notifyPresentationChanged()
                return
            }
            if !segment.hasLiveSensor {
                self.status = .needsAttention(self.errorForNonRunningSegment(segment))
                self.activeSegment = nil
                await self.finalize(segment: segment, audioDuration: nil, end: self.clock.now())
                self.notifyPresentationChanged()
                return
            }
            self.installInterruptionObserver()
            self.status = self.statusForRunningSegment(segment)
            self.startSegmentationTask()
        } catch {
            let observerError = WatchCaptureFailureMapper.observerError(for: error)
            self.status = .needsAttention(observerError)
            if let segment = self.activeSegment, segment.hasLiveSensor {
                self.installInterruptionObserver()
                self.startSegmentationTask()
            } else if let segment = self.activeSegment {
                self.activeSegment = nil
                await self.finalize(segment: segment, audioDuration: nil, end: self.clock.now())
                if !self.status.needsAttention {
                    self.status = .needsAttention(observerError)
                }
            }
        }
        self.notifyPresentationChanged()
    }

    func stop() async {
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.removeInterruptionObserver()
        self.locationProvider.stop()

        if var segment = self.activeSegment {
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
            await self.finalize(segment: segment, audioDuration: audioDuration, end: self.clock.now())
        }

        let attentionAfterFinalize: ObserverError?
        if let runtimeAttention {
            attentionAfterFinalize = runtimeAttention
        } else if case .needsAttention(let error) = self.status {
            attentionAfterFinalize = error
        } else {
            attentionAfterFinalize = nil
        }

        if self.audioSessionIsActive {
            try? self.audioSession.setActive(false, options: [])
            self.audioSessionIsActive = false
        }

        self.activeSegment = nil
        self.audioArmed = false
        self.locationArmed = false
        if let attentionAfterFinalize {
            self.status = .needsAttention(attentionAfterFinalize)
        } else {
            self.status = .off
        }
        self.notifyPresentationChanged()
    }
}

private extension WatchCaptureEngine {
    static let segmentDurationSeconds: TimeInterval = 300

    struct ActiveSegment {
        var directoryURL: URL
        var manifest: WatchSegmentManifest
        var audioURL: URL?
        var locationURL: URL?
        var locationLog: WatchCaptureLocationLog?
        var partialError: ObserverError?

        var hasLiveSensor: Bool {
            self.audioURL != nil || self.locationURL != nil
        }
    }

    func armAudio() async -> Bool {
        guard await self.audioRecorder.requestPermission() else {
            return false
        }
        do {
            try self.audioSession.setCategory(.record, mode: .measurement, options: [])
            try self.audioSession.setActive(true, options: [])
            self.audioSessionIsActive = true
            return true
        } catch {
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
            return false
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
            partialError: nil
        )

        if self.audioArmed {
            let audioURL = self.storage.audioURL(directory: directory)
            do {
                try self.audioRecorder.start(url: audioURL)
                active.audioURL = audioURL
                manifest.sensors.append(.audio)
            } catch {
                self.audioArmed = false
                self.markPartial(&active, error: WatchCaptureFailureMapper.observerError(for: error))
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
                    try await self.clock.sleep(for: .seconds(Self.segmentDurationSeconds))
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

        do {
            try self.openSegment(startedAt: end)
            if let newSegment = self.activeSegment {
                if newSegment.hasLiveSensor {
                    self.status = self.statusForRunningSegment(newSegment)
                } else {
                    self.status = .needsAttention(self.errorForNonRunningSegment(newSegment))
                    self.activeSegment = nil
                    await self.finalize(segment: newSegment, audioDuration: nil, end: end)
                }
            }
        } catch {
            self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
        }

        if let newSegment = self.activeSegment, !newSegment.hasLiveSensor {
            self.status = .needsAttention(self.errorForNonRunningSegment(newSegment))
            self.activeSegment = nil
            await self.finalize(segment: newSegment, audioDuration: nil, end: end)
        }

        if self.activeSegment == nil {
            self.segmentationTask?.cancel()
            self.segmentationTask = nil
            self.locationArmed = false
            self.locationProvider.stop()
            self.audioArmed = false
        }

        await self.finalize(segment: segment, audioDuration: audioDuration, end: end)
        self.notifyPresentationChanged()
    }

    func finalize(segment: ActiveSegment, audioDuration: TimeInterval?, end: Date) async {
        var segment = segment
        var manifest = segment.manifest
        let duration = max(audioDuration ?? end.timeIntervalSince(manifest.startedAt), 0)
        manifest.duration = duration

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
        } catch {
            self.markPartial(&segment, error: WatchCaptureFailureMapper.observerError(for: error))
            self.activeSegment = segment
            self.locationArmed = false
            self.locationProvider.stop()
            if self.audioArmed, segment.audioURL != nil {
                watchCaptureLog.info(
                    "watch sensor lost id=\(segment.manifest.id.uuidString, privacy: .public) sensor=location survivor=audio"
                )
            }
            self.status = .needsAttention(segment.partialError ?? .unavailable(reason: "location unavailable"))
            self.notifyPresentationChanged()
        }
    }

    func handleAuthorizationChanged(_ authorization: WatchLocationAuthorization) {
        guard self.locationArmed, authorization != .authorized else { return }
        self.locationArmed = false
        self.locationProvider.stop()
        let error = ObserverError.unavailable(reason: "location permission unavailable")
        self.runtimeAttention = error
        self.status = .needsAttention(error)
        if self.audioArmed, let segment = self.activeSegment, segment.audioURL != nil {
            watchCaptureLog.info(
                "watch sensor lost id=\(segment.manifest.id.uuidString, privacy: .public) sensor=location survivor=audio"
            )
        }
        self.notifyPresentationChanged()
    }

    func markPartial(_ segment: inout ActiveSegment, error: ObserverError) {
        segment.partialError = error
        segment.manifest.partial = true
        segment.manifest.failureReason = error.message
        self.runtimeAttention = error
        self.status = .needsAttention(error)
    }

    func statusForRunningSegment(_ segment: ActiveSegment) -> WatchCaptureRuntimeStatus {
        if let runtimeAttention {
            return .needsAttention(runtimeAttention)
        }
        if let partialError = segment.partialError {
            return .needsAttention(partialError)
        }
        return .active
    }

    func errorForNonRunningSegment(_ segment: ActiveSegment) -> ObserverError {
        segment.partialError ?? .unavailable(reason: "no sensors available")
    }

    func installInterruptionObserver() {
        self.removeInterruptionObserver()
        self.interruptionObserver = self.notificationCenter.addObserver(
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
        }
    }

    func removeInterruptionObserver() {
        if let interruptionObserver {
            self.notificationCenter.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    func handleInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            self.audioRecorder.pause()
            self.status = .paused
        case .ended:
            do {
                try self.audioRecorder.resume()
                self.status = self.activeSegment == nil ? .off : .active
            } catch {
                self.status = .needsAttention(WatchCaptureFailureMapper.observerError(for: error))
            }
        @unknown default:
            break
        }
        self.notifyPresentationChanged()
    }

    func notifyPresentationChanged() {
        self.onPresentationChanged?(self.ownerPresentation)
    }

    func requestRelayDrain() {
        self.onRelayDrainRequested?()
    }

    func refreshRelayCountsFromDiskThrowing() throws {
        let entries = try self.storage.scanManifests()
        self.queuedCount = entries.filter { $0.manifest.state == .queued }.count
        self.transferringCount = entries.filter { $0.manifest.state == .transferring }.count
        self.handedOffCount = entries.filter {
            $0.manifest.state == .acked || $0.manifest.state == .safeToDelete
        }.count
    }
}
