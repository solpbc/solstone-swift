// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import os

nonisolated private let observerLog = Logger(subsystem: "app.solstone.swift", category: "observer")

nonisolated struct PhoneAudioWriterFault: Sendable, Equatable {
    let segmentID: UUID
    let sessionID: UUID
    let reason: String
}

nonisolated struct PhoneAudioRotationHandoffFailure: Error {
    let priorChunk: ObserverRecordedChunk?
}

nonisolated enum PhoneAudioQueuePushResult: Sendable, Equatable {
    case success
    case faulted(PhoneAudioWriterFault)
    case closed
}

nonisolated final class PhoneAudioPCMQueue: Sendable {
    private struct State {
        var ring: [Float]
        var head: Int = 0
        var tail: Int = 0
        var count: Int = 0
        var isClosed: Bool = false
        var latchedFaultReason: String?
        var faultInstant: ContinuousClock.Instant?
        var admittedFrames: Int64 = 0
        var highWaterFrames = 0
        var isSignaled: Bool = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    let sourceFormat: AVAudioFormat
    let sourceRate: Double
    let channels: Int
    let capacityFrames: Int
    let capacitySamples: Int
    let callbackCap: Int
    let segmentID: UUID
    let sessionID: UUID

    private let lock: OSAllocatedUnfairLock<State>

    init(
        sourceFormat: AVAudioFormat,
        segmentID: UUID,
        sessionID: UUID,
        admissionOpen: Bool = true
    ) {
        self.sourceFormat = sourceFormat
        let rate = sourceFormat.sampleRate
        let channelCount = Int(sourceFormat.channelCount)
        self.sourceRate = rate
        self.channels = channelCount
        self.segmentID = segmentID
        self.sessionID = sessionID

        let capFrames = max(4096, Int(ceil(0.4 * rate)))
        self.callbackCap = capFrames

        let totalFrames = Int(ceil(2.0 * rate))
        let totalSamples = totalFrames * channelCount
        self.capacityFrames = totalFrames
        self.capacitySamples = totalSamples

        let preallocated = [Float](repeating: 0, count: totalSamples)
        self.lock = OSAllocatedUnfairLock(initialState: State(ring: preallocated, isClosed: !admissionOpen))
    }

    var faultSnapshot: (PhoneAudioWriterFault, ContinuousClock.Instant)? {
        self.lock.withLock { state in
            guard let reason = state.latchedFaultReason, let instant = state.faultInstant else { return nil }
            return (PhoneAudioWriterFault(segmentID: self.segmentID, sessionID: self.sessionID, reason: reason), instant)
        }
    }

    var admissionSnapshot: (frames: Int64, highWaterFrames: Int) {
        self.lock.withLock { ($0.admittedFrames, $0.highWaterFrames) }
    }

    /// The worker owns this single preallocated raw PCM buffer. No second copy
    /// or dynamically grown raw array survives the pop.
    func popIntoPCM(_ buffer: AVAudioPCMBuffer) -> (frames: Int, closed: Bool) {
        // The worker exclusively owns this borrowed buffer; the closure is
        // synchronous and neither retains it nor lets it cross executors.
        self.lock.withLockUnchecked { state in
            let frames = min(state.count / self.channels, Int(buffer.frameCapacity))
            buffer.frameLength = AVAudioFrameCount(frames)
            guard frames > 0, let data = buffer.floatChannelData else { return (0, state.isClosed) }
            for frame in 0..<frames {
                for channel in 0..<self.channels {
                    let sample = state.ring[(state.head + frame * self.channels + channel) % self.capacitySamples]
                    if buffer.format.isInterleaved {
                        data[0][frame * self.channels + channel] = sample
                    } else {
                        data[channel][frame] = sample
                    }
                }
            }
            let samples = frames * self.channels
            state.head = (state.head + samples) % self.capacitySamples
            state.count -= samples
            return (frames, state.isClosed)
        }
    }

    func closeAdmission() {
        let waiterToResume = self.lock.withLock { state in
            state.isClosed = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiterToResume?.resume()
    }

    func openAdmission() {
        self.lock.withLock { state in
            if state.latchedFaultReason == nil { state.isClosed = false }
        }
    }

    func push(buffer: AVAudioPCMBuffer) -> PhoneAudioQueuePushResult {
        // AVAudioEngine lends the callback buffer only for this synchronous
        // copy. All retained PCM belongs to the ring protected by this lock.
        let (result, waiterToResume) = self.lock.withLockUnchecked { state -> (PhoneAudioQueuePushResult, CheckedContinuation<Void, Never>?) in
            if let faultReason = state.latchedFaultReason {
                return (.faulted(PhoneAudioWriterFault(segmentID: self.segmentID, sessionID: self.sessionID, reason: faultReason)), nil)
            }
            if state.isClosed {
                return (.closed, nil)
            }

            guard buffer.format.commonFormat == .pcmFormatFloat32,
                  buffer.format.sampleRate == self.sourceRate,
                  Int(buffer.format.channelCount) == self.channels
            else {
                let reason = "audio_conversion_failed"
                state.latchedFaultReason = reason
                state.faultInstant = .now
                state.isClosed = true
                let w = state.waiter
                state.waiter = nil
                return (.faulted(PhoneAudioWriterFault(segmentID: self.segmentID, sessionID: self.sessionID, reason: reason)), w)
            }

            let frames = Int(buffer.frameLength)
            if frames > self.callbackCap {
                let reason = "audio_writer_backpressure"
                state.latchedFaultReason = reason
                state.faultInstant = .now
                state.isClosed = true
                let w = state.waiter
                state.waiter = nil
                return (.faulted(PhoneAudioWriterFault(segmentID: self.segmentID, sessionID: self.sessionID, reason: reason)), w)
            }

            let samplesToAdd = frames * self.channels
            let availableSamples = self.capacitySamples - state.count
            if samplesToAdd > availableSamples {
                let reason = "audio_writer_backpressure"
                state.latchedFaultReason = reason
                state.faultInstant = .now
                state.isClosed = true
                let w = state.waiter
                state.waiter = nil
                return (.faulted(PhoneAudioWriterFault(segmentID: self.segmentID, sessionID: self.sessionID, reason: reason)), w)
            }

            guard let floatData = buffer.floatChannelData else {
                let reason = "audio_conversion_failed"
                state.latchedFaultReason = reason
                state.faultInstant = .now
                state.isClosed = true
                let w = state.waiter
                state.waiter = nil
                return (.faulted(PhoneAudioWriterFault(segmentID: self.segmentID, sessionID: self.sessionID, reason: reason)), w)
            }

            // Copy samples into ring buffer
            if buffer.format.isInterleaved || self.channels == 1 {
                let ptr = floatData[0]
                for i in 0..<samplesToAdd {
                    let destIdx = (state.tail + i) % self.capacitySamples
                    state.ring[destIdx] = ptr[i]
                }
            } else {
                for f in 0..<frames {
                    for ch in 0..<self.channels {
                        let sample = floatData[ch][f]
                        let destIdx = (state.tail + f * self.channels + ch) % self.capacitySamples
                        state.ring[destIdx] = sample
                    }
                }
            }

            state.tail = (state.tail + samplesToAdd) % self.capacitySamples
            state.count += samplesToAdd
            state.admittedFrames += Int64(frames)
            state.highWaterFrames = max(state.highWaterFrames, state.count / self.channels)

            let w = state.waiter
            state.waiter = nil
            if w == nil {
                state.isSignaled = true
            }
            return (.success, w)
        }

        waiterToResume?.resume()
        return result
    }

    func waitNext() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = self.lock.withLock { state -> Bool in
                if state.count > 0 || state.isClosed || state.latchedFaultReason != nil {
                    return true
                } else if state.isSignaled {
                    state.isSignaled = false
                    return true
                } else {
                    state.waiter = continuation
                    return false
                }
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func wakeForDeadline() {
        let waiterToResume = self.lock.withLock { state -> CheckedContinuation<Void, Never>? in
            let w = state.waiter
            state.waiter = nil
            return w
        }
        waiterToResume?.resume()
    }
}

nonisolated private enum PhoneAudioWriterFailure: Error, Equatable {
    case conversion, deadline, unverified
}

actor PhoneAudioFragmentWriter {
    let url: URL
    let segmentID: UUID
    let sessionID: UUID
    let sourceFormat: AVAudioFormat
    let clock: any ObserverClock
    nonisolated let interruptionDirectory: URL
    let onPhoneAudioFault: (@Sendable (PhoneAudioWriterFault) -> Void)?
    nonisolated let queue: PhoneAudioPCMQueue

    private let targetProcessingFormat: AVAudioFormat
    private let rawPCM: AVAudioPCMBuffer
    private let convertedPCM: AVAudioPCMBuffer
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var converter: AVAudioConverter?
    private var resultTask: Task<ObserverRecordedChunk, any Error>?
    private var deadlineTask: Task<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, any Error>?
    private var deadline: Date?
    private var terminalExpired = false
    private var terminalFinished = false
    private var retainedCoreMediaBytes = 0
    private var evidenceFailure: (any Error)?
    private var preservationPending = false
    private(set) var acceptedFrames: Int64 = 0
    private(set) var phase: PhoneAudioWriterReceiptPhase = .writing
    private(set) var faultReason: String?

    private var testReadinessCheck: (@Sendable () -> Bool)?
    private var testConvertedPCMInspector: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var testFaultReceiptWriteError: (any Error)?
    private var testFinishWritingNeverSignals = false
    private var testAppendOverride: (@Sendable (CMSampleBuffer) -> Bool)?

    func setTestReadinessCheck(_ check: (@Sendable () -> Bool)?) { self.testReadinessCheck = check }
    func setTestConvertedPCMInspector(_ inspector: (@Sendable (AVAudioPCMBuffer) -> Void)?) { self.testConvertedPCMInspector = inspector }
    func setTestFaultReceiptWriteError(_ error: (any Error)?) { self.testFaultReceiptWriteError = error }
    func setTestFinishWritingNeverSignals(_ value: Bool) { self.testFinishWritingNeverSignals = value }
    func setTestAppendOverride(_ override: (@Sendable (CMSampleBuffer) -> Bool)?) { self.testAppendOverride = override }

    init(url: URL, segmentID: UUID, sessionID: UUID, sourceFormat: AVAudioFormat,
         clock: any ObserverClock, interruptionDirectory: URL,
         onPhoneAudioFault: (@Sendable (PhoneAudioWriterFault) -> Void)? = nil) throws {
        let rate = sourceFormat.sampleRate
        let channels = sourceFormat.channelCount
        guard sourceFormat.commonFormat == .pcmFormatFloat32, rate.isFinite,
              rate >= 8000, rate <= 192000, channels >= 1, channels <= 8 else {
            throw ObserverError.unavailable(reason: "audio input unavailable")
        }
        self.url = url
        self.segmentID = segmentID
        self.sessionID = sessionID
        self.sourceFormat = sourceFormat
        self.clock = clock
        self.interruptionDirectory = interruptionDirectory
        self.onPhoneAudioFault = onPhoneAudioFault
        self.queue = PhoneAudioPCMQueue(sourceFormat: sourceFormat, segmentID: segmentID,
                                        sessionID: sessionID, admissionOpen: false)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   channels: 1, interleaved: false)!
        self.targetProcessingFormat = target
        guard let raw = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(self.queue.callbackCap)),
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw ObserverError.unavailable(reason: "audio input unavailable")
        }
        self.rawPCM = raw
        self.convertedPCM = converted
    }

    /// Allocated capacities, including an empty ring and idle raw/conversion
    /// buffers. Encoder-internal retention is outside these controlled buffers.
    var applicationRetainedByteCount: Int {
        self.queue.capacitySamples * MemoryLayout<Float>.size
            + Int(self.rawPCM.frameCapacity) * self.queue.channels * MemoryLayout<Float>.size
            + Int(self.convertedPCM.frameCapacity) * MemoryLayout<Float>.size
            + self.retainedCoreMediaBytes
    }

    func start() throws {
        guard self.writer == nil else { throw ObserverError.unavailable(reason: "audio input unavailable") }
        let directory = self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.writeReceipt(phase: .writing)
        let writer = try AVAssetWriter(outputURL: self.url, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 16000)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 16000)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ], sourceFormatHint: self.targetProcessingFormat.formatDescription)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input),
              let converter = AVAudioConverter(from: self.sourceFormat, to: self.targetProcessingFormat) else {
            throw ObserverError.unavailable(reason: "audio input unavailable")
        }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ObserverError.unavailable(reason: "audio input unavailable") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.audioInput = input
        self.converter = converter
        self.queue.openAdmission()
        self.resultTask = Task { try await self.processLoop() }
    }

    /// There is one worker, created by start. Callers can join it, never create a
    /// competing drain/finish loop by stopping or rotating concurrently.
    func runWorkerLoop() async {
        if let resultTask { _ = try? await resultTask.value }
    }

    func checkStartup() throws {
        guard self.faultReason == nil, self.queue.faultSnapshot == nil else {
            throw ObserverError.unavailable(reason: "audio input unavailable")
        }
    }

    func stop() async throws -> ObserverRecordedChunk {
        guard let resultTask else { throw ObserverError.unavailable(reason: "audio input unavailable") }
        if self.terminalFinished && !self.hasStoppedWriting {
            try self.preserveAndCancel()
        }
        self.queue.closeAdmission()
        await self.armDeadline()
        return try await resultTask.value
    }

    private func processLoop() async throws -> ObserverRecordedChunk {
        defer {
            self.terminalFinished = true
            self.deadlineTask?.cancel()
        }
        do {
            while true {
                if let (fault, _) = self.queue.faultSnapshot { await self.latchFault(reason: fault.reason) }
                try self.checkDeadline()
                let (frames, closed) = self.queue.popIntoPCM(self.rawPCM)
                if frames > 0 {
                    try await self.convertAndAppend(terminal: false)
                } else if closed {
                    break
                } else {
                    await self.queue.waitNext()
                }
            }
            try await self.convertAndAppend(terminal: true)
            try await self.finishWriter()
            if self.faultReason != nil {
                throw self.evidenceFailure ?? ObserverError.unavailable(reason: "audio input unavailable")
            }
            try await self.verifyCleanMedia()
            try self.checkDeadline()
            try self.writeReceipt(phase: .completed)
            self.phase = .completed
            return ObserverRecordedChunk(url: self.url, duration: Double(self.acceptedFrames) / 16000)
        } catch {
            await self.latchFault(reason: error is PhoneAudioWriterFailure && (error as? PhoneAudioWriterFailure) == .conversion
                                  ? "audio_conversion_failed" : "audio_writer_failed")
            do { try self.preserveAndCancel() }
            catch { if self.evidenceFailure == nil { self.evidenceFailure = error } }
            throw Self.ownerError(self.evidenceFailure ?? error)
        }
    }

    var hasStoppedWriting: Bool {
        self.writer?.status != .writing && !self.preservationPending
    }

    // cancelWriting synchronously stops mutation but deletes its output URL.
    // A hard link preserves the same inode without copying PCM or file bytes.
    // Recovery also knows this fixed name if the process dies before restoration.
    private func preserveAndCancel() throws {
        guard let writer, writer.status == .writing || self.preservationPending else { return }
        let directory = self.url.deletingLastPathComponent()
        let retained = self.url.appendingPathExtension("retained")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        if writer.status == .writing {
            if names.contains(self.url.lastPathComponent) && !names.contains(retained.lastPathComponent) {
                try FileManager.default.linkItem(at: self.url, to: retained)
            }
            self.preservationPending = names.contains(self.url.lastPathComponent) || names.contains(retained.lastPathComponent)
            writer.cancelWriting()
        }
        if self.preservationPending {
            let current = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if current.contains(self.url.lastPathComponent) {
                if current.contains(retained.lastPathComponent) { try FileManager.default.removeItem(at: retained) }
            } else {
                try FileManager.default.moveItem(at: retained, to: self.url)
            }
            self.preservationPending = false
        }
    }

    private static func ownerError(_ error: any Error) -> ObserverError {
        if let error = error as? ObserverError { return error }
        var cause = error as NSError
        for _ in 0..<8 {
            if (cause.domain == NSCocoaErrorDomain && cause.code == NSFileWriteOutOfSpaceError)
                || (cause.domain == NSPOSIXErrorDomain && cause.code == Int(ENOSPC)) {
                return .diskFull
            }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = underlying
        }
        return .unavailable(reason: "audio input unavailable")
    }

    private func convertAndAppend(terminal: Bool) async throws {
        guard let converter else { throw PhoneAudioWriterFailure.conversion }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        let raw = self.rawPCM
        while true {
            try self.checkDeadline()
            self.convertedPCM.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: self.convertedPCM, error: &conversionError) { _, outStatus in
                let first = supplied.withLock { sent in
                    if sent { return false }
                    sent = true
                    return true
                }
                if !terminal && first {
                    outStatus.pointee = .haveData
                    return raw
                }
                outStatus.pointee = terminal ? .endOfStream : .noDataNow
                return nil
            }
            guard status != .error, conversionError == nil else { throw PhoneAudioWriterFailure.conversion }
            if self.convertedPCM.frameLength > 0 {
                self.testConvertedPCMInspector?(self.convertedPCM)
                try await self.appendConverted()
            }
            if status == .endOfStream || status == .inputRanDry { return }
            guard self.convertedPCM.frameLength > 0 else { throw PhoneAudioWriterFailure.conversion }
        }
    }

    private func appendConverted() async throws {
        guard let input = self.audioInput else { throw PhoneAudioWriterFailure.unverified }
        try await self.awaitReadiness(input: input)
        let count = Int(self.convertedPCM.frameLength)
        let pts = CMTime(value: self.acceptedFrames, timescale: 16000)
        let sample = try Self.makeSampleBuffer(from: self.convertedPCM, offset: 0, frameCount: count, pts: pts)
        self.retainedCoreMediaBytes = count * MemoryLayout<Float>.size
        defer { self.retainedCoreMediaBytes = 0 }
        guard self.testAppendOverride?(sample) ?? input.append(sample) else {
            throw self.writer?.error ?? ObserverError.unavailable(reason: "audio input unavailable")
        }
        self.acceptedFrames += Int64(count)
    }

    private func awaitReadiness(input: AVAssetWriterInput) async throws {
        while true {
            if let (fault, _) = self.queue.faultSnapshot { await self.latchFault(reason: fault.reason) }
            try self.checkDeadline()
            guard self.writer?.status == .writing else {
                throw self.writer?.error ?? ObserverError.unavailable(reason: "audio input unavailable")
            }
            if self.testReadinessCheck?() ?? input.isReadyForMoreMediaData { return }
            try await self.clock.sleep(for: .milliseconds(10))
        }
    }

    private func armDeadline() async {
        guard self.deadline == nil else { return }
        let now = await self.clock.now()
        var began = now
        if let (_, instant) = self.queue.faultSnapshot {
            let elapsed = instant.duration(to: .now).components
            began = now.addingTimeInterval(-Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
        }
        let deadline = began.addingTimeInterval(2)
        self.deadline = deadline
        let clock = self.clock
        let delay = max(0, deadline.timeIntervalSince(now))
        self.deadlineTask = Task { [weak self] in
            do { try await clock.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.expireTerminal()
        }
    }

    private func expireTerminal() async {
        guard !self.terminalFinished, self.phase != .completed else { return }
        self.terminalExpired = true
        await self.latchFault(reason: "audio_writer_failed")
        do { try self.preserveAndCancel() }
        catch { if self.evidenceFailure == nil { self.evidenceFailure = error } }
        let waiter = self.finishWaiter
        self.finishWaiter = nil
        waiter?.resume(throwing: PhoneAudioWriterFailure.deadline)
        self.resultTask?.cancel()
        self.queue.wakeForDeadline()
    }

    private func checkDeadline() throws {
        if self.terminalExpired || Task.isCancelled { throw PhoneAudioWriterFailure.deadline }
    }

    func latchFault(reason: String) async {
        guard self.faultReason == nil, self.phase != .completed else { return }
        self.faultReason = reason
        self.phase = .faulted
        self.queue.closeAdmission()
        await self.armDeadline()
        do {
            if let testError = self.testFaultReceiptWriteError { throw testError }
            try self.writeReceipt(phase: .faulted)
        } catch { self.evidenceFailure = error }
        do {
            try MobileSegmentStore.writeAudioInterruptionAtomic(segmentID: self.segmentID, reason: reason,
                                                               now: await self.clock.now(), in: self.interruptionDirectory)
        } catch { if self.evidenceFailure == nil { self.evidenceFailure = error } }
        self.onPhoneAudioFault?(PhoneAudioWriterFault(segmentID: self.segmentID, sessionID: self.sessionID, reason: reason))
    }

    private func writeReceipt(phase: PhoneAudioWriterReceiptPhase) throws {
        let receipt = PhoneAudioWriterReceipt(segmentID: self.segmentID, phase: phase,
                                               acceptedFrames: self.acceptedFrames,
                                               reason: phase == .faulted ? self.faultReason : nil)
        try MobileSegmentStore.writeAudioWriterReceiptAtomic(receipt,
            to: self.url.deletingLastPathComponent().appendingPathComponent("audio-writer.json"))
    }

    private func finishWriter() async throws {
        try self.checkDeadline()
        guard let input = self.audioInput, let writer else { throw PhoneAudioWriterFailure.unverified }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: self.acceptedFrames, timescale: 16000))
        try await withCheckedThrowingContinuation { continuation in
            self.finishWaiter = continuation
            if !self.testFinishWritingNeverSignals {
                writer.finishWriting { [weak self] in
                    Task { await self?.finishSignaled() }
                }
            }
        }
        try self.checkDeadline()
        guard writer.status == .completed else {
            throw writer.error ?? ObserverError.unavailable(reason: "audio input unavailable")
        }
    }

    private func finishSignaled() {
        guard !self.terminalExpired, !self.terminalFinished else { return }
        let waiter = self.finishWaiter
        self.finishWaiter = nil
        waiter?.resume()
    }

    private func verifyCleanMedia() async throws {
        let file = try AVAudioFile(forReading: self.url)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              file.length > 0 else { throw PhoneAudioWriterFailure.unverified }
        var decoded: Int64 = 0
        while decoded < file.length {
            try self.checkDeadline()
            try file.read(into: self.convertedPCM, frameCount: AVAudioFrameCount(min(4096, file.length - decoded)))
            guard self.convertedPCM.frameLength > 0 else { throw PhoneAudioWriterFailure.unverified }
            decoded += Int64(self.convertedPCM.frameLength)
        }
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: self.url).load(.duration))
        let expected = Double(self.acceptedFrames) / 16000
        guard duration.isFinite, abs(duration - expected) <= 1.0 / 16000,
              abs(Double(decoded) / 16000 - expected) <= 1.0 / 16000 else {
            throw PhoneAudioWriterFailure.unverified
        }
    }

    private static func makeSampleBuffer(
        from pcm: AVAudioPCMBuffer,
        offset: Int,
        frameCount: Int,
        pts: CMTime
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMFormatDescription?
        let descStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard descStatus == noErr, let formatDesc = formatDescription else {
            throw ObserverError.unavailable(reason: "format description create failed")
        }

        let byteCount = frameCount * 4
        guard let channelData = pcm.floatChannelData?[0] else {
            throw ObserverError.unavailable(reason: "no channel data")
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == noErr, let bb = blockBuffer else {
            throw ObserverError.unavailable(reason: "block buffer create failed")
        }

        let srcPtr = channelData.advanced(by: offset)
        let fillStatus = CMBlockBufferReplaceDataBytes(
            with: srcPtr,
            blockBuffer: bb,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard fillStatus == noErr else {
            throw ObserverError.unavailable(reason: "block buffer fill failed")
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 16_000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw ObserverError.unavailable(reason: "sample buffer create failed")
        }

        return sb
    }
}
