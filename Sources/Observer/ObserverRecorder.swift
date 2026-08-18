// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

nonisolated private let observerLog = Logger(subsystem: "app.solstone.swift", category: "observer")

enum ObserverInterruptionEvent: Sendable {
    case began
    case ended
}

enum ObserverEngineFault: Sendable {
    case configurationChange
    case mediaServicesReset
}

nonisolated struct ObserverRecordedChunk: Sendable {
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
    var onEngineFault: (@Sendable (ObserverEngineFault) -> Void)? { get set }

    func requestPermission() async -> Bool
    func start(url: URL, mode: ObserverMode) async throws -> ObserverRecordingStartResult
    func rotate(to url: URL) async throws -> ObserverRecordedChunk?
    func stop() async throws -> ObserverRecordedChunk?
    func pause() async
    func resume() async throws
    func restart() async throws
}

@MainActor
protocol ObserverAudioSession: AnyObject {
    var category: AVAudioSession.Category { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: ObserverAudioSession {}

enum ObserverAudioActivator {
    /// Ensures a record-capable, active session before tapping.
    /// Returns true when THIS call established the record session (caller owns
    /// deactivation in stop()); false when it reused an existing record-capable
    /// session (e.g. an in-progress voice call) — which must never be torn down.
    @MainActor
    static func ensureActiveRecordSession(_ session: ObserverAudioSession) throws -> Bool {
        let category = session.category
        let alreadyRecordCapable = (category == .playAndRecord || category == .record)
        if !alreadyRecordCapable {
            try session.setCategory(.record, mode: .measurement, options: [])
        }
        try session.setActive(true, options: [])
        if alreadyRecordCapable {
            if category == .playAndRecord {
                observerLog.info("observer: reused active voice session")
            } else {
                observerLog.info("observer: reused active audio session")
            }
            return false
        }
        observerLog.info("observer: activated standalone session")
        return true
    }
}

@MainActor
final class LiveObserverRecorder: NSObject, ObserverRecording {
    var onMeter: (@Sendable (Float, TimeInterval) -> Void)? {
        get { self.tapState.onMeter }
        set { self.tapState.onMeter = newValue }
    }

    var onInterruption: (@Sendable (ObserverInterruptionEvent) -> Void)?
    var onEngineFault: (@Sendable (ObserverEngineFault) -> Void)?

    private let engine: AVAudioEngine
    private let session: any ObserverAudioSession
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let tapState = ObserverTapWriter()
    private var didActivateSession = false
    private var interruptionObserver: NSObjectProtocol?
    private var configurationChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        session: any ObserverAudioSession = AVAudioSession.sharedInstance(),
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
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start(url: URL, mode _: ObserverMode) async throws -> ObserverRecordingStartResult {
        self.didActivateSession = try ObserverAudioActivator.ensureActiveRecordSession(self.session)

        try self.installTap(initialURL: url)
        self.installInterruptionObserver()
        self.installEngineFaultObservers()
        do {
            if !self.engine.isRunning {
                self.engine.prepare()
                try self.engine.start()
            }
        } catch {
            self.removeInterruptionObserver()
            self.removeEngineFaultObservers()
            self.engine.inputNode.removeTap(onBus: 0)
            throw error
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
        self.removeEngineFaultObservers()

        let finalized = self.tapState.finalizeAndReset()

        if self.didActivateSession {
            try? self.session.setActive(false, options: [])
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

    func restart() async throws {
        self.engine.inputNode.removeTap(onBus: 0)
        self.engine.stop()
        let inputNode = self.engine.inputNode
        guard let format = Self.validatedTapFormat(inputNode.inputFormat(forBus: 0)) else {
            throw ObserverError.unavailable(reason: "audio input unavailable")
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: self.tapState.makeTapBlock())
        self.engine.prepare()
        try self.engine.start()
    }

    nonisolated static func validatedTapFormat(_ format: AVAudioFormat?) -> AVAudioFormat? {
        guard let format, format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return format
    }
}

private extension LiveObserverRecorder {
    func installTap(initialURL: URL) throws {
        _ = try self.prepareFile(at: initialURL)
        let inputNode = self.engine.inputNode
        guard let format = Self.validatedTapFormat(inputNode.inputFormat(forBus: 0)) else {
            throw ObserverError.unavailable(reason: "audio input unavailable")
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: self.tapState.makeTapBlock())
    }

    func prepareFile(at url: URL) throws -> ObserverRecordedChunk? {
        try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        return self.tapState.swap(to: file, url: url)
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
            Task { @MainActor [weak self] in
                guard let handler = self?.onInterruption else { return }
                switch type {
                case .began:
                    handler(.began)
                case .ended:
                    handler(.ended)
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
}

extension LiveObserverRecorder {
    func installEngineFaultObservers() {
        self.removeEngineFaultObservers()
        self.configurationChangeObserver = self.notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: self.engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let handler = self?.onEngineFault else { return }
                handler(.configurationChange)
            }
        }
        self.mediaServicesResetObserver = self.notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let handler = self?.onEngineFault else { return }
                handler(.mediaServicesReset)
            }
        }
    }

    func removeEngineFaultObservers() {
        if let configurationChangeObserver {
            self.notificationCenter.removeObserver(configurationChangeObserver)
            self.configurationChangeObserver = nil
        }
        if let mediaServicesResetObserver {
            self.notificationCenter.removeObserver(mediaServicesResetObserver)
            self.mediaServicesResetObserver = nil
        }
    }
}

private extension LiveObserverRecorder {
    nonisolated static func decibels(for buffer: AVAudioPCMBuffer) -> Float {
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

nonisolated final class ObserverTapWriter: Sendable {
    private struct State {
        var file: AVAudioFile?
        var url: URL?
        var duration: TimeInterval = 0
        var lastReportedDuration: TimeInterval = 0
        var onMeter: (@Sendable (Float, TimeInterval) -> Void)?
        var cachedConverter: AVAudioConverter?
        var cachedSourceFormat: AVAudioFormat?
        var convertOverride: (@Sendable (AVAudioPCMBuffer, AVAudioFormat) -> AVAudioPCMBuffer?)?
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    var onMeter: (@Sendable (Float, TimeInterval) -> Void)? {
        get { self.lock.withLockUnchecked { $0.onMeter } }
        set { self.lock.withLockUnchecked { $0.onMeter = newValue } }
    }

    /// Test seam: fail conversion while still exposing the original buffer to `write`.
    /// Production never sets this. A `nil` return must not write the source buffer.
    var convertOverride: (@Sendable (AVAudioPCMBuffer, AVAudioFormat) -> AVAudioPCMBuffer?)? {
        get { self.lock.withLockUnchecked { $0.convertOverride } }
        set { self.lock.withLockUnchecked { $0.convertOverride = newValue } }
    }

    /// Installs a freshly created file as the active chunk target and returns the
    /// previously active chunk (if any) so the caller can hand it off (rotate).
    func swap(to file: AVAudioFile, url: URL) -> ObserverRecordedChunk? {
        self.lock.withLockUnchecked { state in
            let prior = Self.chunk(from: state)
            state.file = file
            state.url = url
            state.duration = 0
            state.lastReportedDuration = 0
            state.cachedConverter = nil
            state.cachedSourceFormat = nil
            return prior
        }
    }

    /// Finalizes and clears the active chunk (stop path).
    func finalizeAndReset() -> ObserverRecordedChunk? {
        self.lock.withLockUnchecked { state in
            let chunk = Self.chunk(from: state)
            state.file = nil
            state.url = nil
            state.duration = 0
            state.lastReportedDuration = 0
            state.cachedConverter = nil
            state.cachedSourceFormat = nil
            return chunk
        }
    }

    /// Realtime write path — runs on AVFAudio's audio thread. Touches ZERO @MainActor state.
    func write(_ buffer: AVAudioPCMBuffer) {
        let pending: (@Sendable (Float, TimeInterval) -> Void, Float, TimeInterval)? =
            self.lock.withLockUnchecked { state in
                guard let file = state.file else { return nil }
                let target = file.processingFormat
                let toWrite: AVAudioPCMBuffer
                if let override = state.convertOverride {
                    guard let converted = override(buffer, target) else {
                        observerLog.error("observer buffer convert failed")
                        return nil
                    }
                    toWrite = converted
                } else if Self.matchesFileFormat(buffer.format, target) {
                    toWrite = buffer
                } else if let converted = Self.convert(buffer, to: target, state: &state) {
                    toWrite = converted
                } else {
                    observerLog.error("observer buffer convert failed")
                    return nil
                }
                do {
                    try file.write(from: toWrite)
                    let sampleRate = buffer.format.sampleRate
                    if sampleRate > 0 {
                        state.duration += Double(buffer.frameLength) / sampleRate
                    }
                    let duration = state.duration
                    guard duration - state.lastReportedDuration >= 0.25 else { return nil }
                    state.lastReportedDuration = duration
                    guard let meter = state.onMeter else { return nil }
                    let level = LiveObserverRecorder.decibels(for: buffer)
                    return (meter, level, duration)
                } catch {
                    observerLog.error("observer buffer write failed: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
        if let (meter, level, duration) = pending {
            Task { @MainActor in meter(level, duration) }
        }
    }

    private static func matchesFileFormat(_ source: AVAudioFormat, _ target: AVAudioFormat) -> Bool {
        source.sampleRate == target.sampleRate
            && source.channelCount == target.channelCount
            && source.commonFormat == target.commonFormat
            && source.isInterleaved == target.isInterleaved
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to target: AVAudioFormat,
        state: inout State
    ) -> AVAudioPCMBuffer? {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0, buffer.frameLength > 0 else {
            return nil
        }
        let converter: AVAudioConverter
        if let cached = state.cachedConverter,
           let cachedFormat = state.cachedSourceFormat,
           cachedFormat.sampleRate == buffer.format.sampleRate,
           cachedFormat.channelCount == buffer.format.channelCount {
            converter = cached
        } else {
            guard let created = AVAudioConverter(from: buffer.format, to: target) else { return nil }
            state.cachedConverter = created
            state.cachedSourceFormat = buffer.format
            converter = created
        }
        converter.reset()
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, (Double(buffer.frameLength) * ratio).rounded(.up) + 64))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var provided = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if !provided {
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Forms the tap block in a NONISOLATED context. This is load-bearing: forming
    /// the closure inside the @MainActor installTap method re-inserts the executor
    /// isolation check (verified in prep), so the block MUST be produced here.
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in self.write(buffer) }
    }

    private static func chunk(from state: State) -> ObserverRecordedChunk? {
        guard let url = state.url else { return nil }
        return ObserverRecordedChunk(url: url, duration: state.duration)
    }
}
