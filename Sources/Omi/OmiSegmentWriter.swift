// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

@MainActor
final class OmiSegmentWriter {
    nonisolated static let backgroundSessionIdentifier = "app.solstone.swift.omi-upload"
    nonisolated static let cacheDirectoryName = "OmiObserver"

    private static let chunkDurationSeconds: TimeInterval = 300
    private static let minChunkDurationSeconds = 0.1
    private static let sampleRate: Double = 16_000
    private static let channelCount: AVAudioChannelCount = 1

    private let uploader: ObserverUploader
    private let clock: any ObserverClock
    private let log = Logger(subsystem: "app.solstone.swift", category: "omi-writer")

    private var sessionID: UUID?
    private var chunkIndex = 0
    private var currentChunkStart: Date?
    private var samplesWritten = 0
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var segmentationTask: Task<Void, Never>?

    init(
        uploader: ObserverUploader,
        clock: any ObserverClock = SystemObserverClock()
    ) {
        self.uploader = uploader
        self.clock = clock
    }

    func start() {
        if self.sessionID != nil {
            self.stop()
        }

        self.sessionID = UUID()
        self.chunkIndex = 0
        do {
            try self.openChunk()
            self.startSegmentationTimer()
            self.log.info("omi writer started")
        } catch {
            self.log.error("omi writer start failed: \(String(describing: error), privacy: .public)")
            self.clearState()
        }
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        guard self.sessionID != nil, self.currentFile != nil else { return }

        self.rotateIfElapsed()

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
                self.rotateIfElapsed()
            }
        }
    }

    func openChunk() throws {
        guard let sessionID = self.sessionID else {
            return
        }

        let chunkID = Self.chunkID(sessionID: sessionID, index: self.chunkIndex)
        let url = try self.uploader.inProgressChunkURL(sessionID: sessionID, chunkID: chunkID)
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
    }

    func rotateIfElapsed() {
        guard self.currentFile != nil,
              let currentChunkStart,
              self.clock.now().timeIntervalSince(currentChunkStart) >= Self.chunkDurationSeconds
        else {
            return
        }

        self.finalizeCurrentChunk()
        self.chunkIndex += 1

        do {
            try self.openChunk()
        } catch {
            self.log.error("omi writer rotate failed: \(String(describing: error), privacy: .public)")
        }
    }

    func finalizeCurrentChunk() {
        guard let sessionID = self.sessionID,
              let url = self.currentURL,
              let startedAt = self.currentChunkStart
        else {
            self.currentFile?.close()
            self.clearCurrentChunk()
            return
        }

        let chunkIndex = self.chunkIndex
        let samplesWritten = self.samplesWritten
        self.currentFile?.close()
        self.clearCurrentChunk()

        let duration = Double(samplesWritten) / Self.sampleRate
        guard samplesWritten > 0, duration >= Self.minChunkDurationSeconds else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let sidecar = ChunkSidecar(
            segment: Self.segmentString(for: startedAt, durationSeconds: duration),
            day: Self.dayString(for: startedAt),
            chunkIndex: chunkIndex,
            startedAt: startedAt,
            durationS: duration,
            sessionID: sessionID,
            mode: .meeting
        )
        let uploader = self.uploader
        Task { @MainActor [uploader, url, sidecar] in
            await uploader.enqueue(chunkURL: url, sidecar: sidecar)
        }
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
        self.clearCurrentChunk()
    }

    static func chunkID(sessionID: UUID, index: Int) -> String {
        "\(sessionID.uuidString.lowercased())-\(index)"
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

extension OmiSegmentWriter {
    static func segmentString(for date: Date, durationSeconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = String(repeating: "h".uppercased(), count: 2) + "mmss"
        return "\(formatter.string(from: date))_\(max(1, Int(durationSeconds.rounded())))"
    }
}
