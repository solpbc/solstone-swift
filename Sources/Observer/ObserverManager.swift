// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Observation
import os

private let managerLog = Logger(subsystem: "app.solstone.swift", category: "observer")
private let observerWatchdogTickPeriod: Duration = .seconds(10)
private let observerWatchdogStrikeLimit = 2

struct ObserverSession: Equatable, Sendable {
    let sessionID: UUID
    let mode: ObserverMode
    let startedAt: Date
    let currentChunkIndex: Int
    let elapsed: TimeInterval
}

enum ObserverState: Equatable, Sendable {
    case idle
    case starting
    case active(ObserverSession)
    case stopping
    case error(ObserverError)
}

@MainActor
@Observable
final class ObserverManager {
    var state: ObserverState = .idle

    @ObservationIgnored private let recorder: any ObserverRecording
    @ObservationIgnored private let mobileSegmentEngine: MobileSegmentEngine
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let liveActivity: any ObserverLiveActivitying
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveActivitySecond: Int?
    @ObservationIgnored private var interruptionStartedAt: Date?
    @ObservationIgnored private var currentSessionID: UUID?
    @ObservationIgnored private var currentMode: ObserverMode?
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var currentChunkIndex = 0
    @ObservationIgnored private var silenceWindowStart: TimeInterval?
    @ObservationIgnored private var startCancelled = false
    @ObservationIgnored private var configChangedDuringPause = false
    @ObservationIgnored private var tapProgressCount = 0
    @ObservationIgnored private var watchdogAnchorCount = 0
    @ObservationIgnored private var watchdogStrikes = 0

    init(
        recorder: any ObserverRecording = LiveObserverRecorder(),
        mobileSegmentEngine: MobileSegmentEngine = MobileSegmentEngine(
            uploader: MobileSegmentUploader()
        ),
        clock: any ObserverClock = SystemObserverClock(),
        liveActivity: any ObserverLiveActivitying = ObserverLiveActivity()
    ) {
        self.recorder = recorder
        self.mobileSegmentEngine = mobileSegmentEngine
        self.clock = clock
        self.liveActivity = liveActivity
        self.mobileSegmentEngine.rotateAudio = { [weak recorder] url in
            guard let recorder else { return nil }
            return try await recorder.rotate(to: url)
        }
        self.recorder.onMeter = { [weak self] level, duration in
            Task { @MainActor [weak self] in
                self?.handleMeter(level: level, duration: duration)
            }
        }
        self.recorder.onInterruption = { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleInterruption(event)
            }
        }
        self.recorder.onEngineFault = { [weak self] fault in
            Task { @MainActor [weak self] in
                await self?.handleEngineFault(fault)
            }
        }
    }

    func startSession(mode: ObserverMode) async {
        switch self.state {
        case .idle, .error:
            break
        case .starting, .active, .stopping:
            managerLog.info("observer: start skipped while active")
            return
        }

        self.startCancelled = false
        self.state = .starting
        managerLog.info("observer: session starting")

        guard await self.recorder.requestPermission() else {
            self.state = .error(.permissionDenied)
            return
        }

        if self.startCancelled {
            self.resetRuntime()
            self.state = .idle
            return
        }

        let sessionID = UUID()
        let startedAt = self.clock.now()

        do {
            let chunkURL = try await self.mobileSegmentEngine.startAudio(mode: mode)
            _ = try await self.recorder.start(url: chunkURL, mode: mode)
            if self.startCancelled {
                let finalized = try? await self.recorder.stop()
                await self.mobileSegmentEngine.stopAudio(finalized: finalized)
                self.resetRuntime()
                self.state = .idle
                return
            }

            self.currentSessionID = sessionID
            self.currentMode = mode
            self.sessionStartedAt = startedAt
            self.currentChunkIndex = 0
            self.silenceWindowStart = nil
            self.interruptionStartedAt = nil
            self.tapProgressCount = 0
            self.watchdogAnchorCount = 0
            self.watchdogStrikes = 0
            self.configChangedDuringPause = false
            self.state = .active(ObserverSession(
                sessionID: sessionID,
                mode: mode,
                startedAt: startedAt,
                currentChunkIndex: 0,
                elapsed: 0
            ))
            await self.liveActivity.start(mode: mode, sessionID: sessionID, elapsed: 0)
            self.startElapsedTask()
            self.startWatchdogTask()
        } catch let observerError as ObserverError {
            self.state = .error(observerError)
        } catch {
            self.state = .error(.unavailable(reason: String(describing: error)))
        }
    }

    func stopSession() async {
        let preserveStartCancelled: Bool
        let wasActive: Bool
        switch self.state {
        case .idle:
            await self.endStaleObserverActivities()
            return
        case .starting:
            preserveStartCancelled = true
            wasActive = false
            self.startCancelled = true
            self.state = .stopping
        case .active:
            preserveStartCancelled = false
            wasActive = true
            self.state = .stopping
        case .stopping, .error:
            return
        }

        self.cancelTasks()

        let finalized = try? await self.recorder.stop()
        if wasActive {
            await self.mobileSegmentEngine.stopAudio(finalized: finalized)
        }

        if wasActive {
            await self.liveActivity.end(
                mode: self.currentMode ?? .meeting,
                elapsed: self.sessionStartedAt.map { self.clock.now().timeIntervalSince($0) } ?? 0
            )
        }

        self.resetRuntime(preserveStartCancelled: preserveStartCancelled)
        self.state = .idle
    }

    func endStaleObserverActivities() async {
        await self.liveActivity.endAll()
    }
}

extension ObserverManager {
    func persistEnrolledIfActive(into defaults: UserDefaults = .standard) {
        guard case .active = self.state else { return }
        defaults.set(true, forKey: AudioStorageKey.enrolled)
    }
}

private extension ObserverManager {
    func startElapsedTask() {
        self.elapsedTask?.cancel()
        self.elapsedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
                self.updateElapsed()
            }
        }
    }

    func updateElapsed() {
        guard case .active(let session) = self.state,
              let sessionStartedAt = self.sessionStartedAt
        else { return }

        let elapsed = self.clock.now().timeIntervalSince(sessionStartedAt)
        self.state = .active(ObserverSession(
            sessionID: session.sessionID,
            mode: session.mode,
            startedAt: session.startedAt,
            currentChunkIndex: self.currentChunkIndex,
            elapsed: elapsed
        ))

        let seconds = Int(elapsed)
        if seconds % 15 == 0, self.lastLiveActivitySecond != seconds {
            self.lastLiveActivitySecond = seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.liveActivity.update(mode: session.mode, elapsed: elapsed)
            }
        }
    }

    func handleMeter(level: Float, duration: TimeInterval) {
        guard case .active(let session) = self.state else { return }
        self.tapProgressCount += 1
        guard session.mode == .voiceMemo else { return }

        if level <= -50 {
            if self.silenceWindowStart == nil {
                self.silenceWindowStart = duration
            } else if duration - (self.silenceWindowStart ?? duration) >= 3 {
                managerLog.info("observer: silence-stop")
                Task { @MainActor [weak self] in
                    await self?.stopSession()
                }
            }
        } else {
            self.silenceWindowStart = nil
        }
    }

    func handleEngineFault(_ fault: ObserverEngineFault) async {
        guard case .active = self.state else { return }
        switch fault {
        case .configurationChange:
            guard self.interruptionStartedAt == nil else {
                self.configChangedDuringPause = true
                return
            }
            do {
                try await self.recorder.restart()
                self.rearmWatchdog()
            } catch {
                managerLog.error("observer: engine restart failed")
                await self.stopSession()
                self.state = .error(.audioSessionConflict)
            }
        case .mediaServicesReset:
            managerLog.error("observer: media services reset")
            await self.stopSession()
            self.state = .error(.audioSessionConflict)
        }
    }

    func handleInterruption(_ event: ObserverInterruptionEvent) async {
        guard case .active = self.state else { return }
        switch event {
        case .began:
            self.interruptionStartedAt = self.clock.now()
            await self.recorder.pause()
            self.armInterruptionDeadline()
            self.watchdogTask?.cancel()
            self.watchdogTask = nil
        case .ended:
            self.interruptionDeadlineTask?.cancel()
            self.interruptionDeadlineTask = nil
            guard self.interruptionStartedAt != nil else { return }
            let started = self.interruptionStartedAt!
            let interruptionDuration = self.clock.now().timeIntervalSince(started)
            let rebuild = self.configChangedDuringPause
            self.interruptionStartedAt = nil
            self.configChangedDuringPause = false
            if interruptionDuration <= 60 {
                do {
                    if rebuild {
                        try await self.recorder.restart()
                    } else {
                        try await self.recorder.resume()
                    }
                    self.rearmWatchdog()
                    self.startWatchdogTask()
                } catch {
                    managerLog.error("observer: resume after interruption failed")
                    await self.stopSession()
                    self.state = .error(.audioSessionConflict)
                }
            } else {
                await self.stopSession()
                self.state = .error(.audioSessionConflict)
            }
        }
    }

    func armInterruptionDeadline() {
        self.interruptionDeadlineTask?.cancel()
        self.interruptionDeadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled, self.interruptionStartedAt != nil else { return }
            managerLog.error("observer: interruption end never delivered")
            await self.stopSession()
            self.state = .error(.audioSessionConflict)
        }
    }

    func startWatchdogTask() {
        self.watchdogTask?.cancel()
        self.watchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: observerWatchdogTickPeriod)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if await self.watchdogTick() {
                    return
                }
            }
        }
    }

    func watchdogTick() async -> Bool {
        guard case .active = self.state, self.interruptionStartedAt == nil else {
            self.watchdogStrikes = 0
            self.watchdogAnchorCount = self.tapProgressCount
            return false
        }
        if self.tapProgressCount != self.watchdogAnchorCount {
            self.watchdogAnchorCount = self.tapProgressCount
            self.watchdogStrikes = 0
            return false
        }
        self.watchdogStrikes += 1
        if self.watchdogStrikes >= observerWatchdogStrikeLimit {
            managerLog.error("observer: tap-write stall — stopping")
            await self.stopSession()
            self.state = .error(.audioSessionConflict)
            return true
        }
        return false
    }

    func rearmWatchdog() {
        self.watchdogStrikes = 0
        self.watchdogAnchorCount = self.tapProgressCount
    }

    func cancelTasks() {
        self.elapsedTask?.cancel()
        self.elapsedTask = nil
        self.watchdogTask?.cancel()
        self.watchdogTask = nil
        self.interruptionDeadlineTask?.cancel()
        self.interruptionDeadlineTask = nil
    }

    func resetRuntime(preserveStartCancelled: Bool = false) {
        self.cancelTasks()
        self.interruptionStartedAt = nil
        self.currentSessionID = nil
        self.currentMode = nil
        self.sessionStartedAt = nil
        self.currentChunkIndex = 0
        self.silenceWindowStart = nil
        self.startCancelled = preserveStartCancelled
        self.lastLiveActivitySecond = nil
        self.configChangedDuringPause = false
        self.tapProgressCount = 0
        self.watchdogAnchorCount = 0
        self.watchdogStrikes = 0
    }
}

extension ObserverManager {
    static func segmentString(for date: Date, durationSeconds: Double) -> String {
        ChunkSidecar.segmentString(for: date, durationSeconds: durationSeconds)
    }
}
