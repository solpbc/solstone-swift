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
            engineSources: [.audio, .screencast]
        ))

        XCTAssertEqual(actions, [
            .recordNoArtifact(segmentID: ScreencastFixtures.segmentID, reason: "no_video"),
            .stopBoundary(endedAt: diagnostic.endedAt),
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
            engineSources: [.audio, .location, .screencast]
        ))

        XCTAssertEqual(actions, [
            .recordFinalized(segmentID: ScreencastFixtures.segmentID),
            .stopBoundary(endedAt: runtime.lastSeenAt),
        ])
    }

    func testStopBoundaryProducesExactNextSourceSet() {
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
            engineSources: [.audio, .location, .screencast]
        ))

        XCTAssertEqual(actions.last, .surfaceAttention(.writerFailure))
        XCTAssertEqual(actions.dropLast(), [
            .recordFailed(segmentID: ScreencastFixtures.segmentID, reason: "writer_failure"),
            .stopBoundary(endedAt: diagnostic.endedAt),
        ])
    }

    func testValidLeaseAdoptsAndFinalizesClosingSegment() {
        let lease = ScreencastFixtures.lease(sourceSet: [.audio, .location, .screencast])
        let runtime = ScreencastFixtures.runtime(
            state: .writerOpen,
            segmentID: lease.segmentID
        )

        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: runtime,
            handoff: ScreencastFixtures.handoff(
                revision: lease.revision,
                sourceSet: lease.sourceSet,
                segmentID: lease.segmentID
            ),
            continuationLease: lease,
            filesystem: ScreencastFilesystemState(
                segmentID: lease.fromSegmentID,
                screenExists: true,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: nil
            ),
            engineSources: [.audio, .location, .screencast],
            now: lease.startsAt.addingTimeInterval(1)
        ))

        XCTAssertEqual(actions, [
            .adoptLease(lease, sessionID: runtime.sessionID),
            .recordFinalized(segmentID: lease.fromSegmentID),
            .finalizeSegment(segmentID: lease.fromSegmentID, endedAt: runtime.lastSeenAt),
        ])
        guard case .adoptLease(let adoptedLease, _) = actions.first else {
            return XCTFail("Expected lease adoption")
        }
        XCTAssertEqual(Set(adoptedLease.sourceSet), [.audio, .location, .screencast])
    }

    func testExpiredLeaseSurfacesVisibleFailureAtRollover() {
        let lease = ScreencastFixtures.lease()
        let actions = deriveScreencastReconcileActions(input: self.input(
            handoff: ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast]),
            continuationLease: lease,
            filesystem: ScreencastFilesystemState(
                segmentID: lease.fromSegmentID,
                screenExists: false,
                partExists: true,
                hasFreshLiveness: true,
                terminalDiagnostic: nil
            ),
            engineSources: [.audio, .location, .screencast],
            now: lease.expiresAt.addingTimeInterval(1)
        ))

        XCTAssertEqual(actions, [.surfaceAttention(.staleOrMissingPointer)])
    }

    func testMissingLeaseAtRolloverSurfacesVisibleFailure() {
        let handoff = ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast])
        let actions = deriveScreencastReconcileActions(input: self.input(
            handoff: handoff,
            continuationLease: nil,
            filesystem: ScreencastFilesystemState(
                segmentID: handoff.segmentID,
                screenExists: false,
                partExists: true,
                hasFreshLiveness: true,
                terminalDiagnostic: nil
            ),
            engineSources: [.audio, .location, .screencast],
            now: handoff.rolloverAfter
        ))

        XCTAssertEqual(actions, [.surfaceAttention(.staleOrMissingPointer)])
    }

    func testLeaseAdoptionIsIdempotentAfterTerminalResolution() {
        let lease = ScreencastFixtures.lease()
        let actions = deriveScreencastReconcileActions(input: self.input(
            runtime: ScreencastFixtures.runtime(state: .writerOpen, segmentID: lease.segmentID),
            handoff: ScreencastFixtures.handoff(revision: lease.revision, sourceSet: lease.sourceSet, segmentID: lease.segmentID),
            continuationLease: lease,
            filesystem: ScreencastFilesystemState(
                segmentID: lease.fromSegmentID,
                screenExists: true,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: nil
            ),
            engineSources: [.audio, .location, .screencast],
            manifestResolution: MobileSegmentSourceResolution(state: .finalizedArtifact),
            now: lease.startsAt.addingTimeInterval(1)
        ))

        XCTAssertEqual(actions, [.noOp])
    }
}

private extension ScreencastReconcileDerivationTests {
    func input(
        runtime: MobileSegmentScreencastRuntimeRecord? = nil,
        handoff: MobileSegmentScreencastHandoffRecord? = nil,
        continuationLease: MobileSegmentScreencastContinuationLease? = nil,
        filesystem: ScreencastFilesystemState = .empty,
        engineSources: Set<MobileSegmentSource> = [],
        manifestResolution: MobileSegmentSourceResolution? = nil,
        lastProcessedRuntimeRevision: Int64 = 0,
        lastProcessedHandoffRevision: Int64 = 0,
        now: Date = ScreencastFixtures.start.addingTimeInterval(12)
    ) -> ScreencastReconcileInput {
        ScreencastReconcileInput(
            runtime: runtime,
            handoff: handoff,
            continuationLease: continuationLease,
            filesystem: filesystem,
            engineSources: engineSources,
            manifestResolution: manifestResolution,
            lastProcessedRuntimeRevision: lastProcessedRuntimeRevision,
            lastProcessedHandoffRevision: lastProcessedHandoffRevision,
            now: now
        )
    }
}
