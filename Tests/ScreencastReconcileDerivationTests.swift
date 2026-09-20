// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastReconcileDerivationTests: XCTestCase {
    func testDuplicateNotificationNoOps() {
        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: ScreencastFixtures.runtime(revision: 1),
            handoff: ScreencastFixtures.handoff(revision: 1),
            lastProcessedRuntimeRevision: 1,
            lastProcessedHandoffRevision: 1
        ))

        XCTAssertEqual(actions, [.noOp])
    }

    func testOutOfOrderNotificationReadsLatestRevision() {
        let runtime = ScreencastFixtures.runtime(revision: 3)

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: runtime,
            lastProcessedRuntimeRevision: 1
        ))

        XCTAssertEqual(actions, [.startBoundary(startedAt: runtime.startedAt, sessionID: runtime.sessionID)])
    }

    func testMissingNotificationRecoveredOnForeground() {
        let runtime = ScreencastFixtures.runtime(revision: 1)

        let actions = deriveScreencastReconcileActions(input: self.input(runtime: runtime))

        XCTAssertEqual(actions, [.startBoundary(startedAt: runtime.startedAt, sessionID: runtime.sessionID)])
    }

    func testStartIsOneShot() {
        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: ScreencastFixtures.runtime(revision: 2),
            handoff: ScreencastFixtures.handoff(revision: 2),
            engineSources: [.audio, .screencast]
        ))

        XCTAssertEqual(actions, [.noOp])
    }

    func testStopIsOneShot() {
        let diagnostic = ScreencastFixtures.diagnostic(reason: .writerFailure)
        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: ScreencastFixtures.runtime(state: .failed, segmentID: ScreencastFixtures.segmentID),
            handoff: ScreencastFixtures.handoff(),
            filesystem: ScreencastFilesystemState(
                segmentID: ScreencastFixtures.segmentID,
                screenExists: false,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: diagnostic
            ),
            engineSources: [.audio],
            manifestResolution: MobileSegmentSourceResolution(state: .failedToFinalize, reason: "writer_failure")
        ))

        XCTAssertEqual(actions, [.noOp])
    }

    func testNoVideoDiagnosticRecordsNoArtifactAndNoUpload() {
        let diagnostic = ScreencastFixtures.diagnostic(reason: .noVideo)
        let now = diagnostic.endedAt.addingTimeInterval(8)

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: ScreencastFixtures.runtime(state: .failed, segmentID: ScreencastFixtures.segmentID, acceptedFrameCount: 0),
            handoff: ScreencastFixtures.handoff(),
            filesystem: ScreencastFilesystemState(
                segmentID: ScreencastFixtures.segmentID,
                screenExists: false,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: diagnostic
            ),
            engineSources: [.audio, .screencast],
            now: now
        ))

        XCTAssertEqual(actions, [
            .recordNoArtifact(segmentID: ScreencastFixtures.segmentID, reason: "no_video"),
            .stopBoundary(endedAt: now),
        ])
        XCTAssertFalse(actions.contains { action in
            if case .recordFinalized = action { return true }
            return false
        })
    }

    func testFinalizedScreenRecordsClosingSegmentBeforeStopBoundary() {
        let runtime = ScreencastFixtures.runtime(
            state: .finalized,
            segmentID: ScreencastFixtures.segmentID
        )
        let now = runtime.lastSeenAt.addingTimeInterval(8)

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: runtime,
            handoff: ScreencastFixtures.handoff(),
            filesystem: ScreencastFilesystemState(
                segmentID: ScreencastFixtures.segmentID,
                screenExists: true,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: nil
            ),
            engineSources: [.audio, .location, .screencast],
            now: now
        ))

        XCTAssertEqual(actions, [
            .recordFinalized(segmentID: ScreencastFixtures.segmentID),
            .stopBoundary(endedAt: now),
        ])
    }

    func testStopBoundaryProducesExactNextSourceSet() {
        let diagnostic = ScreencastFixtures.diagnostic(reason: .writerFailure)
        let now = diagnostic.endedAt.addingTimeInterval(8)

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: ScreencastFixtures.runtime(state: .failed, segmentID: ScreencastFixtures.segmentID),
            handoff: ScreencastFixtures.handoff(),
            filesystem: ScreencastFilesystemState(
                segmentID: ScreencastFixtures.segmentID,
                screenExists: false,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: diagnostic
            ),
            engineSources: [.audio, .location, .screencast],
            now: now
        ))

        XCTAssertEqual(actions.last, .surfaceAttention(.writerFailure))
        XCTAssertEqual(actions.dropLast(), [
            .recordFailed(segmentID: ScreencastFixtures.segmentID, reason: "writer_failure"),
            .stopBoundary(endedAt: now),
        ])
    }

    func testLeftoverTerminalManifestResolutionDoesNotBlockNewSession() {
        let previousSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let newSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000200")!
        let leftoverSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000300")!

        let runtime = ScreencastFixtures.runtime(
            sessionID: newSessionID,
            revision: 1,
            state: .broadcastStarted,
            segmentID: nil
        )
        let leftoverHandoff = ScreencastFixtures.handoff(
            sessionID: previousSessionID,
            revision: 1,
            segmentID: leftoverSegmentID
        )

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: runtime,
            handoff: leftoverHandoff,
            filesystem: ScreencastFilesystemState(
                segmentID: leftoverSegmentID,
                screenExists: false,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: nil
            ),
            engineSources: [.audio],
            manifestResolution: MobileSegmentSourceResolution(state: .finalizedArtifact),
            lastSessionID: previousSessionID
        ))

        XCTAssertEqual(actions, [.startBoundary(startedAt: runtime.startedAt, sessionID: newSessionID)])
    }

    func testStaleRevisionDoesNotBlockNewSessionStart() {
        let previousSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let newSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000200")!
        let leftoverSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000300")!

        let runtime = ScreencastFixtures.runtime(
            sessionID: newSessionID,
            revision: 1,
            state: .broadcastStarted,
            segmentID: nil
        )
        let leftoverHandoff = ScreencastFixtures.handoff(
            sessionID: previousSessionID,
            revision: 5,
            segmentID: leftoverSegmentID
        )

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: runtime,
            handoff: leftoverHandoff,
            filesystem: .empty,
            engineSources: [.audio],
            lastProcessedRuntimeRevision: 10,
            lastProcessedHandoffRevision: 5,
            lastSessionID: previousSessionID
        ))

        XCTAssertEqual(actions, [.startBoundary(startedAt: runtime.startedAt, sessionID: newSessionID)])
    }

    func testNewSessionClosesRetainedScreenBoundaryBeforeStarting() {
        let previousSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let newSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000200")!
        let runtime = ScreencastFixtures.runtime(
            sessionID: newSessionID,
            revision: 1,
            state: .broadcastStarted,
            segmentID: nil
        )

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: runtime,
            engineSources: [.audio, .screencast],
            lastSessionID: previousSessionID
        ))

        XCTAssertEqual(actions, [
            .stopBoundary(endedAt: runtime.startedAt),
            .startBoundary(startedAt: runtime.startedAt, sessionID: newSessionID),
        ])
    }

    func testFailedRuntimeWithoutSegmentDoesNotTouchLeftoverSegment() {
        let previousSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let newSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000200")!
        let leftoverSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000300")!

        let runtime = ScreencastFixtures.runtime(
            sessionID: newSessionID,
            revision: 1,
            state: .failed,
            segmentID: nil
        )
        let leftoverHandoff = ScreencastFixtures.handoff(
            sessionID: previousSessionID,
            revision: 1,
            segmentID: leftoverSegmentID
        )

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: runtime,
            handoff: leftoverHandoff,
            filesystem: ScreencastFilesystemState(
                segmentID: leftoverSegmentID,
                screenExists: false,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: nil
            ),
            engineSources: [.audio, .screencast],
            lastSessionID: previousSessionID
        ))

        XCTAssertTrue(actions.contains { action in
            if case .surfaceAttention = action { return true }
            return false
        })
        XCTAssertFalse(actions.contains { action in
            switch action {
            case .recordFinalized(let segmentID),
                 .recordNoArtifact(let segmentID, _),
                 .recordFailed(let segmentID, _),
                 .finalizeSegment(let segmentID, _):
                return segmentID == leftoverSegmentID
            default:
                return false
            }
        })
    }
}

private extension ScreencastReconcileDerivationTests {
    func input(
        runtime: MobileSegmentScreencastRuntimeRecord? = nil,
        handoff: MobileSegmentScreencastHandoffRecord? = nil,
        filesystem: ScreencastFilesystemState = .empty,
        engineSources: Set<MobileSegmentSource> = [],
        manifestResolution: MobileSegmentSourceResolution? = nil,
        lastProcessedRuntimeRevision: Int64 = 0,
        lastProcessedHandoffRevision: Int64 = 0,
        lastSessionID: UUID? = nil,
        now: Date = ScreencastFixtures.start.addingTimeInterval(12)
    ) -> ScreencastReconcileInput {
        ScreencastReconcileInput(
            runtime: runtime,
            handoff: handoff,
            filesystem: filesystem,
            engineSources: engineSources,
            manifestResolution: manifestResolution,
            lastProcessedRuntimeRevision: lastProcessedRuntimeRevision,
            lastProcessedHandoffRevision: lastProcessedHandoffRevision,
            lastSessionID: lastSessionID ?? runtime?.sessionID ?? ScreencastFixtures.sessionID,
            now: now
        )
    }
}
