// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

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
    var screencastRolloverHandler: (@MainActor @Sendable (MobileSegmentScreencastHandoffRecord) -> Void)?
    let callLog: ScreencastCallLog
    var nextHandoff: MobileSegmentScreencastHandoffRecord
    var preparedLeases: [MobileSegmentScreencastContinuationLease] = []
    var adoptedLeases: [MobileSegmentScreencastContinuationLease] = []

    init(
        sources: Set<MobileSegmentSource> = [],
        handoff: MobileSegmentScreencastHandoffRecord = ScreencastFixtures.handoff(),
        callLog: ScreencastCallLog = ScreencastCallLog()
    ) {
        self.currentScreencastSources = sources
        self.nextHandoff = handoff
        self.callLog = callLog
    }

    func startScreencast(at startedAt: Date) async throws -> MobileSegmentScreencastHandoffRecord {
        self.callLog.append("startBoundary")
        self.currentScreencastSources = Set(self.nextHandoff.sourceSet)
        return self.nextHandoff
    }

    func stopScreencast(at endedAt: Date) async throws {
        self.callLog.append("stopBoundary")
        self.currentScreencastSources.remove(.screencast)
    }

    func currentScreencastHandoff() -> MobileSegmentScreencastHandoffRecord? {
        guard self.currentScreencastSources.contains(.screencast) else { return nil }
        return self.nextHandoff
    }

    func prepareScreencastContinuationLease(
        rolloverAt: Date,
        expiresAt: Date
    ) async throws -> MobileSegmentScreencastContinuationLease? {
        guard self.currentScreencastSources.contains(.screencast) else { return nil }
        let lease = MobileSegmentScreencastContinuationLease(
            leaseID: ScreencastFixtures.leaseID,
            revision: self.nextHandoff.revision + 1,
            fromSegmentID: self.nextHandoff.segmentID,
            segmentID: ScreencastFixtures.nextSegmentID,
            sourceSetVersion: self.nextHandoff.sourceSetVersion + 1,
            sourceSet: self.nextHandoff.sourceSet,
            notBefore: rolloverAt,
            startsAt: rolloverAt,
            rolloverAfter: rolloverAt.addingTimeInterval(300),
            expiresAt: expiresAt,
            issuedAt: rolloverAt.addingTimeInterval(-1),
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: ScreencastFixtures.nextSegmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: ScreencastFixtures.nextSegmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: ScreencastFixtures.nextSegmentID)
        )
        self.preparedLeases.append(lease)
        return lease
    }

    func adoptScreencastContinuationLease(
        _ lease: MobileSegmentScreencastContinuationLease
    ) async throws -> MobileSegmentScreencastHandoffRecord {
        self.callLog.append("adoptLease")
        self.adoptedLeases.append(lease)
        self.currentScreencastSources = Set(lease.sourceSet)
        self.nextHandoff = ScreencastFixtures.handoff(
            revision: lease.revision,
            sourceSet: lease.sourceSet,
            segmentID: lease.segmentID
        )
        return self.nextHandoff
    }
}

@MainActor
final class FakeScreencastUploader: ScreencastFacetResolving {
    let callLog: ScreencastCallLog
    var finalized: [UUID] = []
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
    static let leaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000505")!
    static let start = Date(timeIntervalSince1970: 1_780_480_800)

    static func runtime(
        revision: Int64 = 1,
        state: MobileSegmentScreencastRuntimeState = .broadcastStarted,
        segmentID: UUID? = nil,
        acceptedFrameCount: Int = 1
    ) -> MobileSegmentScreencastRuntimeRecord {
        MobileSegmentScreencastRuntimeRecord(
            revision: revision,
            sessionID: Self.sessionID,
            state: state,
            startedAt: Self.start,
            lastSeenAt: Self.start.addingTimeInterval(5),
            currentSegmentID: segmentID,
            currentHandoffRevision: nil,
            acceptedFrameCount: acceptedFrameCount,
            droppedFrameCount: 0
        )
    }

    static func handoff(
        revision: Int64 = 1,
        sourceSet: [MobileSegmentSource] = [.screencast],
        segmentID: UUID = Self.segmentID
    ) -> MobileSegmentScreencastHandoffRecord {
        MobileSegmentScreencastHandoffRecord(
            revision: revision,
            eventID: Self.eventID,
            sessionID: Self.sessionID,
            segmentID: segmentID,
            sourceSetVersion: Int(revision),
            sourceSet: sourceSet,
            startedAt: Self.start,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            desiredState: .writing,
            rolloverAfter: Self.start.addingTimeInterval(300),
            lastHostUpdateAt: Self.start
        )
    }

    static func diagnostic(
        reason: MobileSegmentScreencastDiagnosticReason,
        segmentID: UUID? = Self.segmentID
    ) -> MobileSegmentScreencastDiagnostic {
        MobileSegmentScreencastDiagnostic(
            sessionID: Self.sessionID,
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

    static func lease(
        sourceSet: [MobileSegmentSource] = [.audio, .location, .screencast],
        now: Date = Self.start.addingTimeInterval(300)
    ) -> MobileSegmentScreencastContinuationLease {
        MobileSegmentScreencastContinuationLease(
            leaseID: Self.leaseID,
            revision: 2,
            fromSegmentID: Self.segmentID,
            segmentID: Self.nextSegmentID,
            sourceSetVersion: 2,
            sourceSet: sourceSet,
            notBefore: now,
            startsAt: now,
            rolloverAfter: now.addingTimeInterval(300),
            expiresAt: now.addingTimeInterval(30),
            issuedAt: now.addingTimeInterval(-1),
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: Self.nextSegmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: Self.nextSegmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: Self.nextSegmentID)
        )
    }
}
