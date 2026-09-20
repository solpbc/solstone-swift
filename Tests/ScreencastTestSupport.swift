// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import CoreMedia
import Foundation
import XCTest

@MainActor
final class ScreencastCallLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        self.entries.append(entry)
    }
}

@MainActor
final class FakeScreencastEngine: ScreencastEngineDriving {
    var currentScreencastSources: Set<MobileSegmentSource>
    var screencastRolloverHandler: (@MainActor @Sendable (MobileSegmentScreencastHandoffRecord) -> Bool)?
    let callLog: ScreencastCallLog
    var nextHandoff: MobileSegmentScreencastHandoffRecord
    var stoppedAt: [Date] = []

    init(
        sources: Set<MobileSegmentSource> = [],
        handoff: MobileSegmentScreencastHandoffRecord = ScreencastFixtures.handoff(),
        callLog: ScreencastCallLog = ScreencastCallLog()
    ) {
        self.currentScreencastSources = sources
        self.nextHandoff = handoff
        self.callLog = callLog
    }

    func startScreencast(at startedAt: Date, sessionID: UUID?) async throws -> MobileSegmentScreencastHandoffRecord {
        self.callLog.append("startBoundary")
        self.currentScreencastSources = Set(self.nextHandoff.sourceSet)
        if let sessionID {
            self.nextHandoff = MobileSegmentScreencastHandoffRecord(
                revision: self.nextHandoff.revision,
                eventID: self.nextHandoff.eventID,
                sessionID: sessionID,
                segmentID: self.nextHandoff.segmentID,
                sourceSetVersion: self.nextHandoff.sourceSetVersion,
                sourceSet: self.nextHandoff.sourceSet,
                startedAt: startedAt,
                segmentDirectoryRelativePath: self.nextHandoff.segmentDirectoryRelativePath,
                screenPartRelativePath: self.nextHandoff.screenPartRelativePath,
                screenFinalRelativePath: self.nextHandoff.screenFinalRelativePath,
                desiredState: self.nextHandoff.desiredState,
                scheduleAnchorMs: self.nextHandoff.scheduleAnchorMs,
                schedulePeriodSeconds: self.nextHandoff.schedulePeriodSeconds,
                lastHostUpdateAt: self.nextHandoff.lastHostUpdateAt
            )
        }
        return self.nextHandoff
    }

    func stopScreencast(at endedAt: Date) async throws {
        self.callLog.append("stopBoundary")
        self.stoppedAt.append(endedAt)
        self.currentScreencastSources.remove(.screencast)
    }

    func currentScreencastHandoff() -> MobileSegmentScreencastHandoffRecord? {
        guard self.currentScreencastSources.contains(.screencast) else { return nil }
        return self.nextHandoff
    }
}

@MainActor
final class FakeScreencastUploader: ScreencastFacetResolving {
    let callLog: ScreencastCallLog
    var finalized: [UUID] = []
    var finalizedDurationsBySegmentID: [UUID: TimeInterval] = [:]
    var noArtifacts: [(segmentID: UUID, reason: String)] = []
    var failures: [(segmentID: UUID, reason: String)] = []
    var resolutions: [UUID: MobileSegmentSourceResolution] = [:]

    init(callLog: ScreencastCallLog = ScreencastCallLog()) {
        self.callLog = callLog
    }

    func recordScreencastFinalized(
        segmentID: UUID,
        artifactURL: URL,
        startedAt: Date,
        endedAt: Date,
        durationS: TimeInterval?
    ) throws {
        self.callLog.append("recordFinalized")
        self.finalized.append(segmentID)
        if let durationS {
            self.finalizedDurationsBySegmentID[segmentID] = durationS
        }
    }

    func recordScreencastNoArtifact(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        durationS: TimeInterval?,
        reason: String
    ) throws {
        self.callLog.append("recordNoArtifact")
        self.noArtifacts.append((segmentID, reason))
    }

    func recordScreencastFinalizeFailed(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        reason: String
    ) throws {
        self.callLog.append("recordFailed")
        self.failures.append((segmentID, reason))
    }

    func screencastResolution(segmentID: UUID) -> MobileSegmentSourceResolution? {
        self.resolutions[segmentID]
    }

    func finalizeActiveSegment(segmentID: UUID, endedAt: Date) async {
        self.callLog.append("finalizeSegment")
    }

    func reconcileActiveSegments() async throws {
        self.callLog.append("reconcileActiveSegments")
    }
}

@MainActor
final class StubScreencastDarwin: ScreencastDarwinNotifying {
    var startCallCount = 0
    var stopCallCount = 0
    var postCallCount = 0
    private var handler: (@MainActor @Sendable () -> Void)?

    func start(handler: @escaping @MainActor @Sendable () -> Void) {
        self.startCallCount += 1
        self.handler = handler
    }

    func stop() {
        self.stopCallCount += 1
        self.handler = nil
    }

    func postChanged() {
        self.postCallCount += 1
    }

    func fire() {
        self.handler?()
    }
}

nonisolated enum ScreencastFixtures {
    static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    static let nextSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
    static let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000404")!
    static let start = Date(timeIntervalSince1970: 1_780_480_800)

    static func runtime(
        sessionID: UUID = Self.sessionID,
        revision: Int64 = 1,
        state: MobileSegmentScreencastRuntimeState = .broadcastStarted,
        segmentID: UUID? = nil,
        acceptedFrameCount: Int = 1,
        lastSeenAt: Date = Self.start.addingTimeInterval(5)
    ) -> MobileSegmentScreencastRuntimeRecord {
        MobileSegmentScreencastRuntimeRecord(
            revision: revision,
            sessionID: sessionID,
            state: state,
            startedAt: Self.start,
            lastSeenAt: lastSeenAt,
            currentSegmentID: segmentID,
            currentHandoffRevision: nil,
            acceptedFrameCount: acceptedFrameCount,
            droppedFrameCount: 0
        )
    }

    static func handoff(
        sessionID: UUID = Self.sessionID,
        revision: Int64 = 1,
        sourceSet: [MobileSegmentSource] = [.screencast],
        segmentID: UUID = Self.segmentID
    ) -> MobileSegmentScreencastHandoffRecord {
        MobileSegmentScreencastHandoffRecord(
            revision: revision,
            eventID: Self.eventID,
            sessionID: sessionID,
            segmentID: segmentID,
            sourceSetVersion: Int(revision),
            sourceSet: sourceSet,
            startedAt: Self.start,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            desiredState: .writing,
            scheduleAnchorMs: Int64(Self.start.timeIntervalSince1970 * 1000),
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: Self.start
        )
    }

    static func diagnostic(
        sessionID: UUID = Self.sessionID,
        reason: MobileSegmentScreencastDiagnosticReason,
        segmentID: UUID? = Self.segmentID
    ) -> MobileSegmentScreencastDiagnostic {
        MobileSegmentScreencastDiagnostic(
            sessionID: sessionID,
            segmentID: segmentID,
            handoffRevision: 1,
            reason: reason,
            message: reason.rawValue,
            startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(8),
            acceptedFrameCount: reason == .noVideo ? 0 : 1,
            droppedFrameCount: 0,
            createdAt: Self.start.addingTimeInterval(8)
        )
    }
}

nonisolated func writeFragmentedMovie(to url: URL, frames: Int = 3) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.movieFragmentInterval = CMTime(seconds: 1.0, preferredTimescale: 600)
    let outputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 320,
        AVVideoHeightKey: 240,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
        ]
    )
    writer.add(input)
    guard writer.startWriting() else {
        throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "cannot start writing"])
    }
    writer.startSession(atSourceTime: .zero)

    for i in 0..<frames {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        guard let pb = pixelBuffer else { continue }
        let time = CMTime(seconds: Double(i), preferredTimescale: 600)
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }
        adaptor.append(pb, withPresentationTime: time)
    }
    input.markAsFinished()

    let expectation = XCTestExpectation(description: "finishWriting")
    writer.finishWriting {
        expectation.fulfill()
    }
    let result = XCTWaiter().wait(for: [expectation], timeout: 5.0)
    guard result == .completed else {
        throw NSError(domain: "test", code: -2, userInfo: [NSLocalizedDescriptionKey: "timed out writing movie"])
    }
}

nonisolated func writeLiveness(
    root: URL,
    sessionID: UUID,
    segmentID: UUID,
    handoffRevision: Int64 = 1,
    lastSeenAt: Date,
    acceptedFrameCount: Int = 1,
    droppedFrameCount: Int = 0
) throws {
    let directory = root
        .appendingPathComponent("MobileSegment", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent(segmentID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let liveness = MobileSegmentScreencastSegmentLiveness(
        sessionID: sessionID,
        segmentID: segmentID,
        handoffRevision: handoffRevision,
        lastSeenAt: lastSeenAt,
        acceptedFrameCount: acceptedFrameCount,
        droppedFrameCount: droppedFrameCount
    )
    let liveURL = directory.appendingPathComponent(MobileSegmentScreencastPaths.screenLivenessFilename, isDirectory: false)
    try MobileSegmentScreencastJSONStore.write(liveness, to: liveURL)
}
