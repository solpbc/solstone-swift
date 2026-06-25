// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class WatchComplicationSnapshotTests: XCTestCase {
    func testDerivationMatchesWatchFaceModelStatusTable() {
        let cases: [WatchCaptureRuntimeStatus] = [
            .off,
            .enrolling,
            .active,
            .paused,
            .needsAttention(.diskFull),
        ]

        for status in cases {
            let presentation = WatchCaptureOwnerPresentation(status: status, queuedCount: 0)
            let face = watchFaceModel(for: presentation, isReachable: false)
            let snapshot = WatchComplicationSnapshot(presentation: presentation, isReachable: false)

            XCTAssertEqual(snapshot.stateWord, face.stateWord)
            XCTAssertEqual(snapshot.role, face.stateColorRole)
            XCTAssertEqual(snapshot.showsElapsed, face.showsElapsed)
            XCTAssertEqual(snapshot.trustLine, face.trustLine)
        }
    }

    func testRoleAndHandoffInvariants() {
        let allowed = WatchFaceColorRole.allCases

        let active = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .active, queuedCount: 0),
            isReachable: true
        )
        XCTAssertEqual(active.role, .live)
        XCTAssertTrue(allowed.contains(active.role))

        let sending = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 4, transferringCount: 2),
            isReachable: false
        )
        XCTAssertEqual(sending.handoffLine, SourceVocabulary.watchSendingCount(2))
        XCTAssertNil(sending.handoffSubtext)
        XCTAssertEqual(sending.handoffRole, .flight)
        XCTAssertTrue(allowed.contains(sending.role))
        XCTAssertTrue(allowed.contains(sending.handoffRole!))

        let saved = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 3),
            isReachable: false
        )
        XCTAssertEqual(saved.handoffLine, SourceVocabulary.watchSavedOnWatchCount(3))
        XCTAssertEqual(saved.handoffSubtext, SourceVocabulary.watchWaitingForPhone)
        XCTAssertEqual(saved.handoffRole, .calm)
        XCTAssertTrue(allowed.contains(saved.role))
        XCTAssertTrue(allowed.contains(saved.handoffRole!))

        let attention = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .needsAttention(.diskFull), queuedCount: 0),
            isReachable: false
        )
        XCTAssertEqual(attention.role, .alert)
        XCTAssertTrue(allowed.contains(attention.role))
    }

    func testZeroCountSuppressesHandoff() {
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, transferringCount: 0),
            isReachable: false
        )

        XCTAssertNil(snapshot.handoffLine)
        XCTAssertNil(snapshot.handoffSubtext)
        XCTAssertNil(snapshot.handoffRole)
    }

    func testWaitingForPhoneWordingUsesVocabulary() {
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 1),
            isReachable: false
        )

        XCTAssertEqual(snapshot.handoffSubtext, SourceVocabulary.watchWaitingForPhone)
    }

    func testFurthestClaimStaysAtPhone() {
        XCTAssertEqual(SourceVocabulary.watchPipelineHandedOff, "handed to your iphone")

        let cases = [
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, handedOffCount: 1),
                isReachable: false
            ),
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 2),
                isReachable: false
            ),
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 1, transferringCount: 1),
                isReachable: false
            ),
        ]

        for snapshot in cases {
            let renderedStrings = [
                snapshot.stateWord,
                snapshot.handoffLine,
                snapshot.handoffSubtext,
                snapshot.trustLine,
            ].compactMap(\.self)

            for string in renderedStrings {
                XCTAssertFalse(string.lowercased().contains("in your journal"))
            }
        }
    }

    func testCodableRoundTrip() throws {
        let snapshot = WatchComplicationSnapshot(
            stateWord: SourceVocabulary.watchHeadlineListening,
            role: .live,
            showsElapsed: true,
            sessionStartedAt: Date(timeIntervalSinceReferenceDate: 100),
            handoffLine: SourceVocabulary.watchSendingCount(2),
            handoffSubtext: nil,
            handoffRole: .flight,
            trustLine: SourceVocabulary.trustLineConfigured
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }
}
