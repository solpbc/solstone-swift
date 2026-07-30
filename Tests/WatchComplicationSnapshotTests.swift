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

    func testComplicationMarkDerivationByRuntimeStatus() {
        let cases: [(WatchCaptureRuntimeStatus, WatchComplicationMark)] = [
            (.active, .sun),
            (.off, .cloud),
            (.enrolling, .cloud),
            (.needsAttention(.diskFull), .bang),
        ]

        for (status, mark) in cases {
            let snapshot = WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: status, queuedCount: 0),
                isReachable: false
            )

            XCTAssertEqual(snapshot.mark, mark)
        }
    }

    func testComplicationMarkDerivesCloudForEnrolling() {
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .enrolling, queuedCount: 0),
            isReachable: false
        )

        XCTAssertEqual(snapshot.mark, .cloud)
    }

    func testComplicationMarkAssetNameSeparatesOffFromNil() {
        let offSnapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
            isReachable: false
        )

        let offName = watchComplicationMarkAssetName(for: offSnapshot)
        let nilName = watchComplicationMarkAssetName(for: nil)

        XCTAssertEqual(offName, "SolRingCloud")
        XCTAssertEqual(nilName, "SolRingQuestion")
        XCTAssertNotEqual(offName, nilName)
    }

    func testComplicationInlineTextForNilUsesInlineUnknownCopyOnce() {
        let text = watchComplicationInlineText(for: nil)

        XCTAssertEqual(text, "sol · hasn't checked in")
        XCTAssertEqual(text.components(separatedBy: "sol").count - 1, 1)
    }

    func testComplicationInlineTextUsesHandoffLineThenStateWord() {
        let handoffSnapshot = WatchComplicationSnapshot(
            stateWord: "off",
            role: .calm,
            mark: .cloud,
            showsElapsed: false,
            sessionStartedAt: nil,
            handoffLine: "saved on your watch",
            handoffSubtext: nil,
            handoffRole: .calm,
            trustLine: nil
        )
        let stateSnapshot = WatchComplicationSnapshot(
            stateWord: "on",
            role: .live,
            mark: .sun,
            showsElapsed: false,
            sessionStartedAt: nil,
            handoffLine: nil,
            handoffSubtext: nil,
            handoffRole: nil,
            trustLine: nil
        )

        XCTAssertEqual(watchComplicationInlineText(for: handoffSnapshot), "sol · saved on your watch")
        XCTAssertEqual(watchComplicationInlineText(for: stateSnapshot), "sol · on")
    }

    func testSunMarkIsUnreachableFromNonActiveStatuses() {
        let nonActiveStatuses: [WatchCaptureRuntimeStatus] = [
            .off,
            .enrolling,
            .needsAttention(.diskFull),
        ]

        for status in nonActiveStatuses {
            let snapshot = WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: status, queuedCount: 0),
                isReachable: false
            )

            XCTAssertNotEqual(snapshot.mark, .sun)
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

    func testConfirmingCountDoesNotSurfaceInComplicationHandoff() {
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, confirmingCount: 1),
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

    func testSnapshotCarriesLastVerifiedAudioFromPresentation() {
        let verifiedAt = Date(timeIntervalSince1970: 1_713_624_123)
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: Date(timeIntervalSince1970: 1_713_624_000),
                lastVerifiedAudioAt: verifiedAt
            ),
            isReachable: true
        )

        XCTAssertEqual(snapshot.lastVerifiedAudioAt, verifiedAt)
    }

    func testTimelinePointsIncludePresentAndUnconfirmedHorizonFromVerifiedAudio() {
        let verifiedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let now = verifiedAt.addingTimeInterval(60)
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: verifiedAt,
                lastVerifiedAudioAt: verifiedAt
            ),
            isReachable: true
        )

        let points = watchComplicationTimelinePoints(snapshot: snapshot, now: now)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0], WatchComplicationTimelinePoint(date: now, snapshot: snapshot))
        XCTAssertEqual(
            points[1],
            WatchComplicationTimelinePoint(
                date: verifiedAt.addingTimeInterval(WatchCaptureTiming.segmentDurationSeconds * 2),
                snapshot: nil
            )
        )
    }

    func testTimelinePointsResolveLiveSnapshotToUnknownAfterVerifiedAudioHorizon() {
        let verifiedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: verifiedAt,
                lastVerifiedAudioAt: verifiedAt
            ),
            isReachable: true
        )

        let points = watchComplicationTimelinePoints(
            snapshot: snapshot,
            now: verifiedAt.addingTimeInterval(WatchCaptureTiming.segmentDurationSeconds * 2)
        )

        XCTAssertEqual(points, [
            WatchComplicationTimelinePoint(
                date: verifiedAt.addingTimeInterval(WatchCaptureTiming.segmentDurationSeconds * 2),
                snapshot: nil
            ),
        ])
    }

    func testTimelinePointsResolveMissingVerifiedAudioToUnknown() {
        let snapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: Date(timeIntervalSince1970: 1_713_624_000)
            ),
            isReachable: true
        )
        let now = Date(timeIntervalSince1970: 1_713_624_050)

        XCTAssertEqual(watchComplicationTimelinePoints(snapshot: snapshot, now: now), [
            WatchComplicationTimelinePoint(date: now, snapshot: nil),
        ])
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
            mark: .sun,
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

    func testLegacyDecodeWithoutMarkDerivesFromRole() throws {
        let cases: [(roleJSON: String, expectedMark: WatchComplicationMark)] = [
            (#"{"live":{}}"#, .sun),
            (#"{"calm":{}}"#, .cloud),
            (#"{"alert":{}}"#, .bang),
        ]

        for (roleJSON, expectedMark) in cases {
            let json = """
            {
              "stateWord": "legacy",
              "role": \(roleJSON),
              "showsElapsed": false
            }
            """
            let data = try XCTUnwrap(json.data(using: .utf8))
            let snapshot = try JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)

            XCTAssertEqual(snapshot.mark, expectedMark)
        }
    }
}
