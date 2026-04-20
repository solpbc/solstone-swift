// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

private let observerLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "observer")

enum ObserverInterruptionEvent: Sendable {
    case began
    case ended
}

struct ObserverRecordedChunk: Sendable {
    let url: URL
    let duration: TimeInterval
}

struct ObserverRecordingStartResult: Sendable {
    let didActivateSession: Bool
}

@MainActor
protocol ObserverRecording: AnyObject {
    var onMeter: (@Sendable (Float, TimeInterval) -> Void)? { get set }
    var onInterruption: (@Sendable (ObserverInterruptionEvent) -> Void)? { get set }

    func requestPermission() async -> Bool
    func currentAudioCategory() -> AVAudioSession.Category
    func start(url: URL, mode: ObserverMode) async throws -> ObserverRecordingStartResult
    func rotate(to url: URL) async throws -> ObserverRecordedChunk?
    func stop() async throws -> ObserverRecordedChunk?
    func pause() async
    func resume() async throws
}

@MainActor
final class LiveObserverRecorder: NSObject, ObserverRecording {
    var onMeter: (@Sendable (Float, TimeInterval) -> Void)?
    var onInterruption: (@Sendable (ObserverInterruptionEvent) -> Void)?

    private let engine: AVAudioEngine
    private let session: AVAudioSession
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var currentDuration: TimeInterval = 0
    private var lastReportedDuration: TimeInterval = 0
    private var didActivateSession = false
    private var interruptionObserver: NSObjectProtocol?

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        session: AVAudioSession = .sharedInstance(),
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default
    ) {
        self.engine = engine
        self.session = session
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
        super.init()
    }

    func requestPermission() async -> Bool {
        switch self.session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                self.session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func currentAudioCategory() -> AVAudioSession.Category {
        self.session.category
    }

    func start(url: URL, mode _: ObserverMode) async throws -> ObserverRecordingStartResult {
        let category = self.session.category
        if category == .ambient {
            try self.session.setCategory(.record, mode: .measurement, options: [])
            try self.session.setActive(true)
            self.didActivateSession = true
            observerLog.info("observer: activated standalone session")
        } else {
            self.didActivateSession = false
            if category == .playAndRecord {
                observerLog.info("observer: reused active voice session")
            } else {
                observerLog.info("observer: reused active audio session")
            }
        }

        try self.installTap(initialURL: url)
        self.installInterruptionObserver()
        if !self.engine.isRunning {
            self.engine.prepare()
            try self.engine.start()
        }
        return ObserverRecordingStartResult(didActivateSession: self.didActivateSession)
    }

    func rotate(to url: URL) async throws -> ObserverRecordedChunk? {
        try self.prepareFile(at: url)
    }

    func stop() async throws -> ObserverRecordedChunk? {
        self.engine.inputNode.removeTap(onBus: 0)
        self.engine.stop()
        self.removeInterruptionObserver()

        let finalized = self.lockedFinalizeChunk()
        self.currentFile = nil
        self.currentURL = nil
        self.currentDuration = 0
        self.lastReportedDuration = 0

        if self.didActivateSession {
            try? self.session.setActive(false)
        }
        self.didActivateSession = false
        return finalized
    }

    func pause() async {
        self.engine.pause()
    }

    func resume() async throws {
        if !self.engine.isRunning {
            self.engine.prepare()
            try self.engine.start()
        }
    }
}

private extension LiveObserverRecorder {
    func installTap(initialURL: URL) throws {
        _ = try self.prepareFile(at: initialURL)
        let inputNode = self.engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }
    }

    func prepareFile(at url: URL) throws -> ObserverRecordedChunk? {
        try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let finalized = self.lockedFinalizeChunk()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        self.lock.lock()
        self.currentFile = file
        self.currentURL = url
        self.currentDuration = 0
        self.lastReportedDuration = 0
        self.lock.unlock()
        return finalized
    }

    func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard let currentFile else { return }
        do {
            try currentFile.write(from: buffer)
            let sampleRate = buffer.format.sampleRate
            if sampleRate > 0 {
                self.currentDuration += Double(buffer.frameLength) / sampleRate
            }

            let duration = self.currentDuration
            if duration - self.lastReportedDuration >= 0.25 {
                self.lastReportedDuration = duration
                let level = Self.decibels(for: buffer)
                let meter = self.onMeter
                Task { @MainActor in
                    meter?(level, duration)
                }
            }
        } catch {
            observerLog.error("observer buffer write failed: \(String(describing: error), privacy: .public)")
        }
    }

    func lockedFinalizeChunk() -> ObserverRecordedChunk? {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard let currentURL else { return nil }
        return ObserverRecordedChunk(url: currentURL, duration: self.currentDuration)
    }

    func installInterruptionObserver() {
        self.removeInterruptionObserver()
        self.interruptionObserver = self.notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: self.session,
            queue: nil
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            let handler = self?.onInterruption
            Task { @MainActor in
                switch type {
                case .began:
                    handler?(.began)
                case .ended:
                    handler?(.ended)
                @unknown default:
                    break
                }
            }
        }
    }

    func removeInterruptionObserver() {
        if let interruptionObserver {
            self.notificationCenter.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    static func decibels(for buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return -160 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return -160 }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = samples[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        guard rms > 0 else { return -160 }
        return 20 * log10(rms)
    }
}
