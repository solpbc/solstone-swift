// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Observation
import os

private let managerLog = Logger(subsystem: "app.solstone.swift", category: "observer")

struct ObserverSession: Equatable, Sendable {
    let sessionID: UUID
    let mode: ObserverMode
    let startedAt: Date
    let currentChunkIndex: Int
    let elapsed: TimeInterval
}

enum ObserverError: Equatable, Sendable {
    case permissionDenied
    case audioSessionConflict
    case diskFull
    case uploadFailed(chunkID: String)
    case unavailable(reason: String)

    var message: String {
        switch self {
        case .permissionDenied:
            "microphone access is required to listen"
        case .audioSessionConflict:
            "audio session changed while listening"
        case .diskFull:
            "storage is full"
        case .uploadFailed:
            "upload failed"
        case .unavailable(let reason):
            reason
        }
    }
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
    @ObservationIgnored private let uploader: ObserverUploader
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let liveActivity: any ObserverLiveActivitying
    @ObservationIgnored private var segmentationTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveActivitySecond: Int?
    @ObservationIgnored private var interruptionStartedAt: Date?
    @ObservationIgnored private var currentSessionID: UUID?
    @ObservationIgnored private var currentMode: ObserverMode?
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var currentChunkStartedAt: Date?
    @ObservationIgnored private var currentChunkIndex = 0
    @ObservationIgnored private var currentChunkID: String?
    @ObservationIgnored private var currentChunkURL: URL?
    @ObservationIgnored private var silenceWindowStart: TimeInterval?
    @ObservationIgnored private var startCancelled = false

    init(
        recorder: any ObserverRecording = LiveObserverRecorder(),
        uploader: ObserverUploader = ObserverUploader(),
        clock: any ObserverClock = SystemObserverClock(),
        liveActivity: any ObserverLiveActivitying = ObserverLiveActivity()
    ) {
        self.recorder = recorder
        self.uploader = uploader
        self.clock = clock
        self.liveActivity = liveActivity
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
        let chunkID = Self.chunkID(sessionID: sessionID, index: 0)

        do {
            let chunkURL = try self.uploader.inProgressChunkURL(sessionID: sessionID, chunkID: chunkID)
            _ = try await self.recorder.start(url: chunkURL, mode: mode)
            if self.startCancelled {
                _ = try? await self.recorder.stop()
                self.resetRuntime()
                self.state = .idle
                return
            }

            self.currentSessionID = sessionID
            self.currentMode = mode
            self.sessionStartedAt = startedAt
            self.currentChunkStartedAt = startedAt
            self.currentChunkIndex = 0
            self.currentChunkID = chunkID
            self.currentChunkURL = chunkURL
            self.silenceWindowStart = nil
            self.interruptionStartedAt = nil
            self.state = .active(ObserverSession(
                sessionID: sessionID,
                mode: mode,
                startedAt: startedAt,
                currentChunkIndex: 0,
                elapsed: 0
            ))
            await self.liveActivity.start(mode: mode, sessionID: sessionID, elapsed: 0)
            self.startElapsedTask()
            self.startSegmentationTask()
        } catch {
            let message = String(describing: error)
            self.state = .error(.unavailable(reason: message))
        }
    }

    func stopSession() async {
        let preserveStartCancelled: Bool
        switch self.state {
        case .idle:
            return
        case .starting:
            preserveStartCancelled = true
            self.startCancelled = true
            self.state = .stopping
        case .active:
            preserveStartCancelled = false
            self.state = .stopping
        case .stopping, .error:
            return
        }

        self.cancelTasks()

        let finalized = try? await self.recorder.stop()
        if let finalized,
           let sessionID = self.currentSessionID,
           let mode = self.currentMode,
           let startedAt = self.currentChunkStartedAt
        {
            await self.enqueueChunk(
                finalized,
                sessionID: sessionID,
                chunkIndex: self.currentChunkIndex,
                startedAt: startedAt,
                mode: mode
            )
            await self.liveActivity.end(mode: mode, elapsed: self.sessionStartedAt.map { self.clock.now().timeIntervalSince($0) } ?? finalized.duration)
        }

        self.resetRuntime(preserveStartCancelled: preserveStartCancelled)
        self.state = .idle
    }
}

private extension ObserverManager {
    func startSegmentationTask() {
        self.segmentationTask?.cancel()
        self.segmentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(300))
                } catch {
                    return
                }
                guard case .active = self.state else { return }
                await self.rotateChunk()
            }
        }
    }

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

    func rotateChunk() async {
        guard let sessionID = self.currentSessionID,
              let mode = self.currentMode,
              let startedAt = self.currentChunkStartedAt
        else { return }

        let nextIndex = self.currentChunkIndex + 1
        let nextChunkID = Self.chunkID(sessionID: sessionID, index: nextIndex)

        do {
            let nextChunkURL = try self.uploader.inProgressChunkURL(sessionID: sessionID, chunkID: nextChunkID)
            let finalized = try await self.recorder.rotate(to: nextChunkURL)
            if let finalized {
                await self.enqueueChunk(
                    finalized,
                    sessionID: sessionID,
                    chunkIndex: self.currentChunkIndex,
                    startedAt: startedAt,
                    mode: mode
                )
            }

            self.currentChunkIndex = nextIndex
            self.currentChunkID = nextChunkID
            self.currentChunkURL = nextChunkURL
            self.currentChunkStartedAt = self.clock.now()
            self.silenceWindowStart = nil
            self.updateElapsed()
        } catch {
            self.state = .error(.unavailable(reason: String(describing: error)))
        }
    }

    func enqueueChunk(
        _ finalized: ObserverRecordedChunk,
        sessionID: UUID,
        chunkIndex: Int,
        startedAt: Date,
        mode: ObserverMode
    ) async {
        let sidecar = ChunkSidecar(
            segment: Self.segmentString(for: startedAt),
            day: Self.dayString(for: startedAt),
            chunkIndex: chunkIndex,
            startedAt: startedAt,
            durationS: finalized.duration,
            sessionID: sessionID,
            mode: mode
        )
        await self.uploader.enqueue(chunkURL: finalized.url, sidecar: sidecar)
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
        guard case .active(let session) = self.state,
              session.mode == .voiceMemo
        else { return }

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

    func handleInterruption(_ event: ObserverInterruptionEvent) async {
        switch event {
        case .began:
            self.interruptionStartedAt = self.clock.now()
            await self.recorder.pause()
        case .ended:
            let interruptionDuration = self.clock.now().timeIntervalSince(self.interruptionStartedAt ?? self.clock.now())
            self.interruptionStartedAt = nil
            if interruptionDuration <= 60 {
                try? await self.recorder.resume()
            } else {
                await self.stopSession()
                self.state = .error(.audioSessionConflict)
            }
        }
    }

    func cancelTasks() {
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.elapsedTask?.cancel()
        self.elapsedTask = nil
    }

    func resetRuntime(preserveStartCancelled: Bool = false) {
        self.cancelTasks()
        self.interruptionStartedAt = nil
        self.currentSessionID = nil
        self.currentMode = nil
        self.sessionStartedAt = nil
        self.currentChunkStartedAt = nil
        self.currentChunkIndex = 0
        self.currentChunkID = nil
        self.currentChunkURL = nil
        self.silenceWindowStart = nil
        self.startCancelled = preserveStartCancelled
        self.lastLiveActivitySecond = nil
    }

    static func chunkID(sessionID: UUID, index: Int) -> String {
        "\(sessionID.uuidString.lowercased())-\(index)"
    }

    static func segmentString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
