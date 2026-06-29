// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ReplayKit
import os

nonisolated private let screencastWriterLog = Logger(subsystem: "app.solstone.swift", category: "screencast-writer")

nonisolated enum ScreencastBroadcastWriterOutcome: Equatable, Sendable {
    case completed
    case noVideo
    case finalizeTimeout
    case writerFailure(String)
    case filesystemHandoffFailure(String)

    var diagnosticReason: MobileSegmentScreencastDiagnosticReason? {
        switch self {
        case .completed:
            nil
        case .noVideo:
            .noVideo
        case .finalizeTimeout:
            .finalizeTimeout
        case .writerFailure:
            .writerFailure
        case .filesystemHandoffFailure:
            .filesystemHandoffFailure
        }
    }
}

/// Video-only writer for ReplayKit broadcast upload samples.
///
/// `nonisolated` keeps this class off the app's default main-actor isolation.
/// ReplayKit calls the handler on its sample delivery queue; this writer is
/// only touched by that handler and uses a structural in-flight counter for
/// deterministic backpressure.
nonisolated final class ScreencastBroadcastWriter {
    static let finishTimeoutSeconds: TimeInterval = 3

    private let fileManager: FileManager
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var rootURL: URL?
    private var handoff: MobileSegmentScreencastHandoffRecord?
    private var partURL: URL?
    private var finalURL: URL?
    private var livenessURL: URL?
    private var lastAcceptedPTSSeconds: Double?
    private var lastLivenessWriteAt: Date?
    private var sessionStarted = false
    private var inFlightFrameCount = 0
    private(set) var acceptedFrameCount = 0
    private(set) var droppedFrameCount = 0

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func open(
        rootURL: URL,
        handoff: MobileSegmentScreencastHandoffRecord,
        now: Date
    ) throws {
        try MobileSegmentScreencastPaths.validateRelativePath(handoff.screenPartRelativePath)
        try MobileSegmentScreencastPaths.validateRelativePath(handoff.screenFinalRelativePath)
        let partURL = MobileSegmentScreencastPaths.url(root: rootURL, relativePath: handoff.screenPartRelativePath)
        let finalURL = MobileSegmentScreencastPaths.url(root: rootURL, relativePath: handoff.screenFinalRelativePath)
        let livenessURL = MobileSegmentScreencastPaths.url(
            root: rootURL,
            relativePath: MobileSegmentScreencastPaths.screenLivenessRelativePath(segmentID: handoff.segmentID)
        )
        try self.fileManager.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: partURL.path) {
            try self.fileManager.removeItem(at: partURL)
        }
        self.rootURL = rootURL
        self.handoff = handoff
        self.partURL = partURL
        self.finalURL = finalURL
        self.livenessURL = livenessURL
        self.writer = nil
        self.videoInput = nil
        self.lastAcceptedPTSSeconds = nil
        self.acceptedFrameCount = 0
        self.droppedFrameCount = 0
        self.sessionStarted = false
        self.writeLiveness(now: now, force: true)
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, now: Date) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsSeconds = pts.seconds
        guard MobileSegmentScreencastFramePolicy.acceptsVideoFrame(
            ptsSeconds: ptsSeconds,
            lastAcceptedPTSSeconds: self.lastAcceptedPTSSeconds
        ) else { return }

        if MobileSegmentScreencastFramePolicy.shouldDropFrame(inFlightFrameCount: self.inFlightFrameCount) {
            self.droppedFrameCount += 1
            self.writeLiveness(now: now)
            return
        }

        self.inFlightFrameCount += 1
        defer { self.inFlightFrameCount -= 1 }

        if self.writer == nil {
            let orientation = Self.orientation(from: sampleBuffer)
            let canvas = MobileSegmentScreencastGeometry.outputDimensions(
                sourceWidth: CVPixelBufferGetWidth(sourceBuffer),
                sourceHeight: CVPixelBufferGetHeight(sourceBuffer),
                orientation: orientation
            )
            do {
                try self.configure(
                    canvas: canvas,
                    sourceWidth: CVPixelBufferGetWidth(sourceBuffer),
                    sourceHeight: CVPixelBufferGetHeight(sourceBuffer),
                    orientation: orientation,
                    sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer)
                )
            } catch {
                screencastWriterLog.error("writer configure failed: \(String(describing: error), privacy: .public)")
                return
            }
        }

        guard let writer,
              let videoInput
        else { return }

        if !self.sessionStarted {
            guard writer.startWriting() else {
                screencastWriterLog.error("writer startWriting failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            writer.startSession(atSourceTime: pts)
            self.sessionStarted = true
        }

        guard writer.status == .writing,
              videoInput.isReadyForMoreMediaData
        else { return }

        if videoInput.append(sampleBuffer) {
            self.lastAcceptedPTSSeconds = ptsSeconds
            self.acceptedFrameCount += 1
            self.writeLiveness(now: now)
        }
    }

    func finish(now: Date) -> ScreencastBroadcastWriterOutcome {
        guard self.acceptedFrameCount > 0 else {
            if let partURL {
                try? self.fileManager.removeItem(at: partURL)
            }
            return .noVideo
        }
        guard let writer,
              let videoInput,
              let partURL,
              let finalURL else {
            return .writerFailure("writer_not_open")
        }
        guard writer.status == .writing else {
            return .writerFailure("writer_status_\(writer.status.rawValue)")
        }

        videoInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.finishTimeoutSeconds) == .success else {
            return .finalizeTimeout
        }
        guard writer.status == .completed else {
            return .writerFailure(writer.error?.localizedDescription ?? "finish_failed")
        }

        do {
            try MobileSegmentScreencastJSONStore.finalizePart(partURL: partURL, finalURL: finalURL, fileManager: self.fileManager)
            self.writeLiveness(now: now, force: true)
            return .completed
        } catch {
            return .filesystemHandoffFailure(String(describing: error))
        }
    }

    func writeLiveness(now: Date, force: Bool = false) {
        guard let livenessURL,
              let handoff else { return }
        if !force,
           let lastLivenessWriteAt,
           now.timeIntervalSince(lastLivenessWriteAt) < MobileSegmentScreencastLivenessPolicy.livenessRefreshIntervalSeconds {
            return
        }
        self.lastLivenessWriteAt = now
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: handoff.sessionID,
            segmentID: handoff.segmentID,
            handoffRevision: handoff.revision,
            lastSeenAt: now,
            acceptedFrameCount: self.acceptedFrameCount,
            droppedFrameCount: self.droppedFrameCount
        )
        do {
            try MobileSegmentScreencastJSONStore.write(liveness, to: livenessURL, fileManager: self.fileManager)
        } catch {
            screencastWriterLog.error("liveness write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension ScreencastBroadcastWriter {
    nonisolated func configure(
        canvas: MobileSegmentScreencastCanvasDimensions,
        sourceWidth: Int,
        sourceHeight: Int,
        orientation: MobileSegmentScreencastSampleOrientation,
        sourceFormatHint: CMFormatDescription?
    ) throws {
        guard let partURL else {
            throw NSError(domain: "ScreencastBroadcastWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing_part_url"])
        }
        let writer = try AVAssetWriter(outputURL: partURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.movieFragmentInterval = CMTime(
            seconds: MobileSegmentScreencastWriterConfiguration.movieFragmentIntervalSeconds,
            preferredTimescale: 600
        )

        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: 1_000_000,
            AVVideoExpectedSourceFrameRateKey: 1,
            AVVideoMaxKeyFrameIntervalKey: 1,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: videoCompression,
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: sourceFormatHint)
        video.expectsMediaDataInRealTime = true
        video.transform = Self.videoTransform(
            sourceWidth: CGFloat(sourceWidth),
            sourceHeight: CGFloat(sourceHeight),
            canvasWidth: CGFloat(canvas.width),
            canvasHeight: CGFloat(canvas.height),
            orientation: orientation
        )

        guard writer.canAdd(video), !MobileSegmentScreencastWriterConfiguration.writesAudioTrack else {
            throw NSError(domain: "ScreencastBroadcastWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "writer_rejected_video"])
        }
        writer.add(video)
        self.writer = writer
        self.videoInput = video
    }

    nonisolated static func videoTransform(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        orientation: MobileSegmentScreencastSampleOrientation
    ) -> CGAffineTransform {
        let displayedWidth = orientation.swapsAxes ? sourceHeight : sourceWidth
        let displayedHeight = orientation.swapsAxes ? sourceWidth : sourceHeight
        let fit = MobileSegmentScreencastGeometry.aspectFit(
            sourceWidth: displayedWidth,
            sourceHeight: displayedHeight,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        return Self.orientationTransform(width: sourceWidth, height: sourceHeight, orientation: orientation)
            .scaledBy(x: fit.scale, y: fit.scale)
            .translatedBy(x: fit.offsetX / fit.scale, y: fit.offsetY / fit.scale)
    }

    nonisolated static func orientationTransform(
        width: CGFloat,
        height: CGFloat,
        orientation: MobileSegmentScreencastSampleOrientation
    ) -> CGAffineTransform {
        switch orientation {
        case .up:
            return .identity
        case .upMirrored:
            return CGAffineTransform(translationX: width, y: 0).scaledBy(x: -1, y: 1)
        case .down:
            return CGAffineTransform(translationX: width, y: height).rotated(by: .pi)
        case .downMirrored:
            return CGAffineTransform(translationX: 0, y: height).scaledBy(x: 1, y: -1)
        case .right:
            return CGAffineTransform(translationX: height, y: 0).rotated(by: .pi / 2)
        case .rightMirrored:
            return CGAffineTransform(translationX: height, y: width)
                .rotated(by: .pi / 2)
                .scaledBy(x: -1, y: 1)
        case .left:
            return CGAffineTransform(translationX: 0, y: width).rotated(by: -.pi / 2)
        case .leftMirrored:
            return CGAffineTransform(rotationAngle: -.pi / 2).scaledBy(x: -1, y: 1)
        }
    }

    nonisolated static func orientation(from sampleBuffer: CMSampleBuffer) -> MobileSegmentScreencastSampleOrientation {
        let key = RPVideoSampleOrientationKey as CFString
        guard let value = CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: nil) as? NSNumber,
              let orientation = MobileSegmentScreencastSampleOrientation(rawValue: value.uint32Value) else {
            return .up
        }
        return orientation
    }
}
