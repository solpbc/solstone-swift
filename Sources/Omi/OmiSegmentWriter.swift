// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

@MainActor
final class OmiSegmentWriter {
    nonisolated static let cacheDirectoryName = "OmiObserver"

    private static let chunkDurationSeconds: TimeInterval = 300
    private static let minChunkDurationSeconds = 0.1
    private static let maxChunkOpenAttempts = 3
    private static let sampleRate: Double = 16_000
    private static let channelCount: AVAudioChannelCount = 1

    private let transferEnqueuer: ObserverAudioTransferEnqueuer
    private let cacheRootURL: URL
    private let fileManager: FileManager
    private let clock: any ObserverClock
    private let log = Logger(subsystem: "app.solstone.swift", category: "omi-writer")

    var onChunkFinalized: ((_ day: String, _ durationS: TimeInterval, _ identity: String) -> Void)?
    var onWriterFault: (() -> Void)?

    private(set) var droppedSamples = 0
    private(set) var failedOpens = 0

    private var sessionID: UUID?
    private var chunkIndex = 0
    private var currentChunkStart: Date?
    private var samplesWritten = 0
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var segmentationTask: Task<Void, Never>?
    private var consecutiveChunkOpenFailures = 0
    private var didNotifyWriterFaultForCurrentWedge = false

    init(
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: any ObserverClock = SystemObserverClock()
    ) {
        self.transferEnqueuer = transferEnqueuer
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
            ?? (try? AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(Self.cacheDirectoryName, isDirectory: true))
            ?? fileManager.temporaryDirectory
                .appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        self.clock = clock
    }

    func start() {
        guard self.sessionID == nil else { return }

        self.sessionID = UUID()
        self.chunkIndex = 0
        do {
            try self.openChunk()
            self.startSegmentationTimer()
            self.log.info("omi writer started")
        } catch {
            self.noteChunkOpenFailure(error, context: "start")
            self.clearState()
        }
    }

    var isRunning: Bool { self.sessionID != nil }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        guard self.sessionID != nil else { return }

        _ = self.rotateIfElapsed()
        guard self.ensureCurrentChunk(droppedSampleCount: samples.count) else { return }

        guard let audioFile = self.currentFile else { return }
        guard let buffer = Self.makeBuffer(samples) else {
            self.log.error("omi writer buffer unavailable")
            return
        }

        do {
            try audioFile.write(from: buffer)
            self.samplesWritten += samples.count
        } catch {
            self.log.error("omi writer write failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.finalizeCurrentChunk()
        self.clearState()
        self.log.info("omi writer stopped")
    }

    func finalizeOpenChunk() async {
        let hadOpenChunk = self.currentURL != nil
        await self.finalizeCurrentChunkAwaitingEnqueue()
        if hadOpenChunk {
            self.chunkIndex += 1
        }
    }

    static func makeBuffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, samples.count <= Int(UInt32.max) else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        ) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?[0]
        else {
            return nil
        }

        samples.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                channel.update(from: baseAddress, count: samples.count)
            }
        }
        buffer.frameLength = frameCount
        return buffer
    }
}

private extension OmiSegmentWriter {
    static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    func startSegmentationTimer() {
        self.segmentationTask?.cancel()
        self.segmentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(Self.chunkDurationSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = self.rotateIfElapsed()
            }
        }
    }

    func openChunk() throws {
        guard let sessionID = self.sessionID else {
            return
        }

        let chunkID = Self.chunkID(sessionID: sessionID, index: self.chunkIndex)
        let url = try self.inProgressChunkURL(sessionID: sessionID, chunkID: chunkID)
        let file = try AVAudioFile(
            forWriting: url,
            settings: Self.aacSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        self.currentFile = file
        self.currentURL = url
        self.currentChunkStart = self.clock.now()
        self.samplesWritten = 0
        self.resetChunkOpenFailureState()
    }

    func rotateIfElapsed() -> Bool {
        guard self.currentFile != nil,
              let currentChunkStart,
              self.clock.now().timeIntervalSince(currentChunkStart) >= Self.chunkDurationSeconds
        else {
            return true
        }

        self.finalizeCurrentChunk()
        self.chunkIndex += 1

        do {
            try self.openChunk()
            return true
        } catch {
            self.noteChunkOpenFailure(error, context: "rotate")
            return false
        }
    }

    func finalizeCurrentChunk() {
        guard let finalizedChunk = self.takeFinalizedChunk() else { return }
        let transferEnqueuer = self.transferEnqueuer
        Task { @MainActor [weak self, transferEnqueuer, finalizedChunk] in
            do {
                _ = try await transferEnqueuer.enqueueOmiChunkMovingFile(
                    chunkURL: finalizedChunk.url,
                    sidecar: finalizedChunk.sidecar
                )
                self?.notifyChunkFinalized(finalizedChunk)
            } catch {
                self?.log.error("omi writer enqueue failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func finalizeCurrentChunkAwaitingEnqueue() async {
        guard let finalizedChunk = self.takeFinalizedChunk() else { return }
        do {
            _ = try await self.transferEnqueuer.enqueueOmiChunkMovingFile(
                chunkURL: finalizedChunk.url,
                sidecar: finalizedChunk.sidecar
            )
            self.notifyChunkFinalized(finalizedChunk)
        } catch {
            self.log.error("omi writer enqueue failed: \(String(describing: error), privacy: .public)")
        }
    }

    func takeFinalizedChunk() -> FinalizedChunk? {
        guard let sessionID = self.sessionID,
              let url = self.currentURL,
              let startedAt = self.currentChunkStart
        else {
            self.currentFile?.close()
            self.clearCurrentChunk()
            return nil
        }

        let chunkIndex = self.chunkIndex
        let samplesWritten = self.samplesWritten
        self.currentFile?.close()
        self.clearCurrentChunk()

        let duration = Double(samplesWritten) / Self.sampleRate
        guard samplesWritten > 0, duration >= Self.minChunkDurationSeconds else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let day = ObserverSegmentNaming.dayString(for: startedAt)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: duration),
            day: day,
            chunkIndex: chunkIndex,
            startedAt: startedAt,
            durationS: duration,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
        return FinalizedChunk(
            url: url,
            sidecar: sidecar,
            day: day,
            durationS: duration,
            identity: Self.chunkID(sessionID: sessionID, index: chunkIndex)
        )
    }

    func notifyChunkFinalized(_ finalizedChunk: FinalizedChunk) {
        self.onChunkFinalized?(
            finalizedChunk.day,
            finalizedChunk.durationS,
            finalizedChunk.identity
        )
    }

    func clearCurrentChunk() {
        self.currentFile = nil
        self.currentURL = nil
        self.currentChunkStart = nil
        self.samplesWritten = 0
    }

    func clearState() {
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.currentFile?.close()
        self.sessionID = nil
        self.chunkIndex = 0
        self.resetChunkOpenFailureState()
        self.clearCurrentChunk()
    }

    func ensureCurrentChunk(droppedSampleCount: Int) -> Bool {
        guard self.currentFile == nil else {
            return true
        }
        while self.currentFile == nil && self.consecutiveChunkOpenFailures < Self.maxChunkOpenAttempts {
            do {
                try self.openChunk()
                return true
            } catch {
                self.noteChunkOpenFailure(error, context: "append")
            }
        }
        self.droppedSamples += droppedSampleCount
        return false
    }

    func noteChunkOpenFailure(_ error: any Error, context: String) {
        self.failedOpens += 1
        self.consecutiveChunkOpenFailures += 1
        self.log.error("omi writer \(context, privacy: .public) open failed: \(String(describing: error), privacy: .public)")
        guard self.consecutiveChunkOpenFailures >= Self.maxChunkOpenAttempts,
              !self.didNotifyWriterFaultForCurrentWedge
        else {
            return
        }
        self.didNotifyWriterFaultForCurrentWedge = true
        self.onWriterFault?()
    }

    func resetChunkOpenFailureState() {
        self.consecutiveChunkOpenFailures = 0
        self.didNotifyWriterFaultForCurrentWedge = false
    }

    static func chunkID(sessionID: UUID, index: Int) -> String {
        "\(sessionID.uuidString.lowercased())-\(index)"
    }

    func sessionDirectoryURL(sessionID: UUID) -> URL {
        self.cacheRootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func inProgressDirectoryURL(sessionID: UUID) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID).appendingPathComponent("in-progress", isDirectory: true)
    }

    func inProgressChunkURL(sessionID: UUID, chunkID: String) throws -> URL {
        let directory = self.inProgressDirectoryURL(sessionID: sessionID)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
    }
}

private struct FinalizedChunk: Sendable {
    let url: URL
    let sidecar: ChunkSidecar
    let day: String
    let durationS: TimeInterval
    let identity: String
}
