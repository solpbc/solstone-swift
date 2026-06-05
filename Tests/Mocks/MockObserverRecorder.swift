// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation

@MainActor
final class MockObserverRecorder: ObserverRecording {
    var onMeter: (@Sendable (Float, TimeInterval) -> Void)?
    var onInterruption: (@Sendable (ObserverInterruptionEvent) -> Void)?
    var permissionGranted = true
    var permissionDelay: Duration?
    var startCallCount = 0
    var rotateCallCount = 0
    var stopCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0
    var didActivateSession = true
    var startError: (any Error)?
    var rotateError: (any Error)?
    var stopError: (any Error)?
    var lastStartURL: URL?
    var lastRotateURL: URL?
    var currentURL: URL?
    var nextChunkDuration: TimeInterval = 5

    func requestPermission() async -> Bool {
        if let permissionDelay {
            try? await Task.sleep(for: permissionDelay)
        }
        return self.permissionGranted
    }

    func start(url: URL, mode: ObserverMode) async throws -> ObserverRecordingStartResult {
        self.startCallCount += 1
        self.lastStartURL = url
        self.currentURL = url
        if let startError { throw startError }
        try Data("audio".utf8).write(to: url)
        return ObserverRecordingStartResult(didActivateSession: self.didActivateSession)
    }

    func rotate(to url: URL) async throws -> ObserverRecordedChunk? {
        self.rotateCallCount += 1
        self.lastRotateURL = url
        if let rotateError { throw rotateError }
        let finalized = self.currentURL.map { ObserverRecordedChunk(url: $0, duration: self.nextChunkDuration) }
        self.currentURL = url
        try Data("audio".utf8).write(to: url)
        return finalized
    }

    func stop() async throws -> ObserverRecordedChunk? {
        self.stopCallCount += 1
        if let stopError { throw stopError }
        defer { self.currentURL = nil }
        return self.currentURL.map { ObserverRecordedChunk(url: $0, duration: self.nextChunkDuration) }
    }

    func pause() async {
        self.pauseCallCount += 1
    }

    func resume() async throws {
        self.resumeCallCount += 1
    }

    func emitMeter(level: Float, duration: TimeInterval) {
        self.onMeter?(level, duration)
    }

    func emitInterruption(_ event: ObserverInterruptionEvent) {
        self.onInterruption?(event)
    }
}
