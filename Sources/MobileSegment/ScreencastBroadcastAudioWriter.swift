// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import os

nonisolated private let screencastAudioLog = Logger(subsystem: "app.solstone.swift", category: "screencast-audio")

nonisolated final class ScreencastBroadcastAudioWriter: ScreencastBroadcastAudioWriting, @unchecked Sendable {
    static let finishTimeoutSeconds: TimeInterval = 1

    private let fileManager: FileManager
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var rootURL: URL?
    private var handoff: MobileSegmentScreencastHandoffRecord?
    private var partURL: URL?
    private var finalURL: URL?
    private var sessionStarted = false
    private(set) var isOpen = false
    private(set) var acceptedSampleCount = 0
    var testFinishWritingNeverSignals = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func open(
        rootURL: URL,
        handoff: MobileSegmentScreencastHandoffRecord,
        now: Date
    ) throws {
        let partRelative = MobileSegmentScreencastPaths.screenAudioPartRelativePath(segmentID: handoff.segmentID)
        let finalRelative = MobileSegmentScreencastPaths.screenAudioRelativePath(segmentID: handoff.segmentID)
        try MobileSegmentScreencastPaths.validateRelativePath(partRelative)
        try MobileSegmentScreencastPaths.validateRelativePath(finalRelative)

        let partURL = MobileSegmentScreencastPaths.url(root: rootURL, relativePath: partRelative)
        let finalURL = MobileSegmentScreencastPaths.url(root: rootURL, relativePath: finalRelative)

        try self.fileManager.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: partURL.path) {
            try self.fileManager.removeItem(at: partURL)
        }

        self.rootURL = rootURL
        self.handoff = handoff
        self.partURL = partURL
        self.finalURL = finalURL
        self.writer = nil
        self.audioInput = nil
        self.sessionStarted = false
        self.acceptedSampleCount = 0
        self.isOpen = true
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, now: Date) throws {
        guard self.isOpen else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.seconds.isNaN, pts.seconds.isFinite else { return }

        if self.writer == nil {
            try self.configure(sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
        }

        guard let writer = self.writer, let audioInput = self.audioInput else { return }

        if !self.sessionStarted {
            guard writer.startWriting() else {
                let message = writer.error?.localizedDescription ?? "unknown start error"
                screencastAudioLog.error("audio writer startWriting failed: \(message, privacy: .public)")
                throw NSError(domain: "ScreencastBroadcastAudioWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            writer.startSession(atSourceTime: pts)
            self.sessionStarted = true
        }

        var attempts = 0
        while writer.status == .writing, !audioInput.isReadyForMoreMediaData, attempts < 40 {
            Thread.sleep(forTimeInterval: 0.005)
            attempts += 1
        }

        guard writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }

        if !audioInput.append(sampleBuffer) {
            let message = writer.error?.localizedDescription ?? "audio append failed"
            screencastAudioLog.error("audio writer append failed: \(message, privacy: .public)")
            throw NSError(domain: "ScreencastBroadcastAudioWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        self.acceptedSampleCount += 1
    }

    func finish(now: Date) {
        guard self.isOpen else { return }
        self.isOpen = false

        guard let writer = self.writer,
              let audioInput = self.audioInput,
              let partURL = self.partURL,
              let finalURL = self.finalURL
        else {
            self.writer = nil
            self.audioInput = nil
            return
        }

        guard writer.status == .writing else {
            screencastAudioLog.error("audio writer status not writing on finish: \(writer.status.rawValue, privacy: .public)")
            self.writer = nil
            self.audioInput = nil
            return
        }

        audioInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)

        if self.testFinishWritingNeverSignals {
            self.testFinishWritingNeverSignals = false
            // Intentionally don't call finishWriting / don't signal semaphore to exercise 1s timeout
        } else {
            writer.finishWriting {
                semaphore.signal()
            }
        }

        guard semaphore.wait(timeout: .now() + Self.finishTimeoutSeconds) == .success else {
            screencastAudioLog.error("audio writer finalize timed out after \(Self.finishTimeoutSeconds, privacy: .public)s")
            self.writer = nil
            self.audioInput = nil
            return
        }

        guard writer.status == .completed else {
            screencastAudioLog.error("audio writer finish failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            self.writer = nil
            self.audioInput = nil
            return
        }

        do {
            try MobileSegmentScreencastJSONStore.finalizePart(partURL: partURL, finalURL: finalURL, fileManager: self.fileManager)
        } catch {
            screencastAudioLog.error("audio writer finalizePart failed: \(String(describing: error), privacy: .public)")
        }

        self.writer = nil
        self.audioInput = nil
    }

    private func configure(sourceFormatHint: CMFormatDescription?) throws {
        guard let partURL = self.partURL else {
            throw NSError(domain: "ScreencastBroadcastAudioWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "missing_part_url"])
        }

        let writer = try AVAssetWriter(outputURL: partURL, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = true
        writer.movieFragmentInterval = CMTime(
            seconds: MobileSegmentScreencastWriterConfiguration.movieFragmentIntervalSeconds,
            preferredTimescale: 600
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: audioSettings,
            sourceFormatHint: sourceFormatHint
        )
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(audioInput) else {
            throw NSError(domain: "ScreencastBroadcastAudioWriter", code: 4, userInfo: [NSLocalizedDescriptionKey: "writer_rejected_audio"])
        }

        writer.add(audioInput)
        self.writer = writer
        self.audioInput = audioInput
    }
}
