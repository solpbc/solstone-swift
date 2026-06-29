// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastLeaseTests: XCTestCase {
    func testValidLeaseContinues() {
        let now = ScreencastFixtures.start.addingTimeInterval(300)
        let lease = ScreencastFixtures.lease(now: now)

        let decision = evaluateScreencastContinuationLease(
            lease,
            currentHandoff: ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast]),
            currentSegmentID: ScreencastFixtures.segmentID,
            now: now
        )

        XCTAssertEqual(decision, .valid(lease))
    }

    func testLeaseSourceSetPreservesAudioLocation() {
        let now = ScreencastFixtures.start.addingTimeInterval(300)
        let lease = ScreencastFixtures.lease(sourceSet: [.audio, .location, .screencast], now: now)

        let actions = deriveScreencastReconcileActions(input: ScreencastReconcileInput(
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
            manifestResolution: nil,
            lastProcessedRuntimeRevision: 0,
            lastProcessedHandoffRevision: 0,
            now: now
        ))

        guard case .adoptLease(let adoptedLease, _) = actions.first else {
            return XCTFail("Expected lease adoption")
        }
        XCTAssertEqual(Set(adoptedLease.sourceSet), [.audio, .location, .screencast])
    }

    func testExpiredLeaseWritesDiagnostic() {
        let now = ScreencastFixtures.start.addingTimeInterval(400)
        let lease = ScreencastFixtures.lease(now: ScreencastFixtures.start.addingTimeInterval(300))

        let decision = evaluateScreencastContinuationLease(
            lease,
            currentHandoff: ScreencastFixtures.handoff(sourceSet: [.screencast]),
            currentSegmentID: ScreencastFixtures.segmentID,
            now: now
        )

        XCTAssertEqual(decision, .failed(.staleOrMissingPointer))
    }

    func testAmbiguousLeaseFailsVisible() {
        let now = ScreencastFixtures.start.addingTimeInterval(300)
        let lease = ScreencastFixtures.lease(sourceSet: [.audio, .location], now: now)

        let decision = evaluateScreencastContinuationLease(
            lease,
            currentHandoff: ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast]),
            currentSegmentID: ScreencastFixtures.segmentID,
            now: now
        )

        XCTAssertEqual(decision, .failed(.staleOrMissingPointer))
    }

    func testMissingLeaseAtRolloverFailsVisible() {
        let decision = evaluateScreencastContinuationLease(
            nil,
            currentHandoff: ScreencastFixtures.handoff(),
            currentSegmentID: ScreencastFixtures.segmentID,
            now: ScreencastFixtures.start.addingTimeInterval(300)
        )

        XCTAssertEqual(decision, .failed(.staleOrMissingPointer))
    }
}
