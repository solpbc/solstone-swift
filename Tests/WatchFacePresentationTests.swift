// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class WatchFacePresentationTests: XCTestCase {
    func testStatusTable() {
        let cases: [(WatchCaptureRuntimeStatus, String, WatchFaceMark, WatchFaceColorRole, Bool)] = [
            (.active, SourceVocabulary.watchHeadlineListening, .active, .live, true),
            (.enrolling, SourceVocabulary.watchHeadlineEnrolling, .active, .live, false),
            (.needsAttention(.diskFull), ObserverError.diskFull.message, .alert, .alert, false),
            (.off, SourceVocabulary.watchHeadlineOff, .activeDimmed, .calm, false),
        ]

        for (status, stateWord, markVariant, stateColorRole, showsElapsed) in cases {
            let model = watchFaceModel(
                for: WatchCaptureOwnerPresentation(status: status, queuedCount: 0),
                isReachable: false
            )
            XCTAssertEqual(model.stateWord, stateWord)
            XCTAssertEqual(model.markVariant, markVariant)
            XCTAssertEqual(model.stateColorRole, stateColorRole)
            XCTAssertEqual(model.showsElapsed, showsElapsed)
        }
    }

    func testAudioUnavailableStateDoesNotStringifyStructuredError() {
        let model = watchFaceModel(
            for: WatchCaptureOwnerPresentation(
                status: .needsAttention(.unavailable(reason: "audio unavailable")),
                queuedCount: 0,
                transferringCount: 25
            ),
            isReachable: true
        )

        XCTAssertEqual(model.stateWord, "audio unavailable")
        XCTAssertEqual(model.compactHandoff?.line, SourceVocabulary.watchSendingCount(25))

        var renderedStrings = [
            model.stateWord,
            model.compactHandoff?.line,
            model.compactHandoff?.subtext,
            model.trustLine,
            model.linkLine,
        ].compactMap(\.self)
        renderedStrings.append(contentsOf: model.detailRows.map(\.label))

        for string in renderedStrings {
            XCTAssertFalse(string.contains("unavailable("))
            XCTAssertFalse(string.contains("\""))
        }
    }

    func testOffWithBacklogKeepsStateAndShowsHandoff() {
        let model = watchFaceModel(
            for: WatchCaptureOwnerPresentation(status: .off, queuedCount: 8),
            isReachable: false
        )

        XCTAssertEqual(model.stateWord, SourceVocabulary.watchHeadlineOff)
        XCTAssertEqual(model.compactHandoff?.line, SourceVocabulary.watchSavedOnWatchCount(8))
        XCTAssertEqual(model.compactHandoff?.subtext, SourceVocabulary.watchWaitingForPhone)
        XCTAssertEqual(model.compactHandoff?.role, .calm)
    }

    func testSendingTakesHandoffPriority() {
        let model = watchFaceModel(
            for: WatchCaptureOwnerPresentation(status: .off, queuedCount: 5, transferringCount: 3),
            isReachable: false
        )

        XCTAssertEqual(model.compactHandoff?.line, SourceVocabulary.watchSendingCount(3))
        XCTAssertNil(model.compactHandoff?.subtext)
        XCTAssertEqual(model.compactHandoff?.role, .flight)
    }

    func testDetailRowsSuppressZerosAndKeepOrder() {
        let empty = watchFaceModel(
            for: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
            isReachable: false
        )
        XCTAssertNil(empty.compactHandoff)
        XCTAssertTrue(empty.detailRows.isEmpty)

        let mixed = watchFaceModel(
            for: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 2,
                transferringCount: 0,
                confirmingCount: 1,
                handedOffCount: 4
            ),
            isReachable: false
        )
        XCTAssertEqual(
            mixed.detailRows,
            [
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: 2),
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineConfirming, value: 1),
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineHandedOff, value: 4),
            ]
        )

        let confirmingOnly = watchFaceModel(
            for: WatchCaptureOwnerPresentation(status: .active, queuedCount: 0, confirmingCount: 1),
            isReachable: false
        )
        XCTAssertEqual(
            confirmingOnly.detailRows,
            [
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineConfirming, value: 1),
            ]
        )

        let allRows = watchFaceModel(
            for: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 2,
                transferringCount: 3,
                confirmingCount: 1,
                handedOffCount: 4
            ),
            isReachable: false
        )
        XCTAssertEqual(
            allRows.detailRows,
            [
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: 2),
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineSending, value: 3),
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineConfirming, value: 1),
                WatchFaceDetailRow(label: SourceVocabulary.watchPipelineHandedOff, value: 4),
            ]
        )
    }

    func testElapsedOnlyForActive() {
        XCTAssertTrue(
            watchFaceModel(
                for: WatchCaptureOwnerPresentation(status: .active, queuedCount: 0),
                isReachable: false
            ).showsElapsed
        )

        let statuses: [WatchCaptureRuntimeStatus] = [
            .enrolling,
            .needsAttention(.diskFull),
            .off,
        ]
        for status in statuses {
            XCTAssertFalse(
                watchFaceModel(
                    for: WatchCaptureOwnerPresentation(status: status, queuedCount: 0),
                    isReachable: false
                ).showsElapsed
            )
        }
    }

    func testTrustLineAlwaysPresent() {
        let statuses: [WatchCaptureRuntimeStatus] = [
            .active,
            .enrolling,
            .needsAttention(.diskFull),
            .off,
        ]

        for status in statuses {
            XCTAssertEqual(
                watchFaceModel(
                    for: WatchCaptureOwnerPresentation(
                        status: status,
                        queuedCount: status == .off ? 1 : 0
                    ),
                    isReachable: false
                ).trustLine,
                SourceVocabulary.trustLineConfigured
            )
        }
    }

    func testLinkLineAndRange() {
        let reachable = watchFaceModel(
            for: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
            isReachable: true
        )
        XCTAssertEqual(reachable.linkLine, SourceVocabulary.watchLinkConnected)
        XCTAssertTrue(reachable.linkInRange)

        let unreachable = watchFaceModel(
            for: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
            isReachable: false
        )
        XCTAssertEqual(unreachable.linkLine, SourceVocabulary.watchLinkNotConnected)
        XCTAssertFalse(unreachable.linkInRange)
    }

    func testColorRoleInvariant() {
        XCTAssertEqual(WatchFaceColorRole.allCases, [.live, .flight, .calm, .alert])
        let allowed = WatchFaceColorRole.allCases
        let statuses: [WatchCaptureRuntimeStatus] = [
            .active,
            .enrolling,
            .needsAttention(.diskFull),
            .off,
        ]
        let countCases = [
            (queued: 0, transferring: 0, confirming: 0, handedOff: 0),
            (queued: 1, transferring: 0, confirming: 0, handedOff: 0),
            (queued: 0, transferring: 1, confirming: 0, handedOff: 0),
            (queued: 0, transferring: 0, confirming: 1, handedOff: 0),
            (queued: 1, transferring: 1, confirming: 1, handedOff: 1),
        ]

        for status in statuses {
            for counts in countCases {
                for isReachable in [true, false] {
                    let model = watchFaceModel(
                        for: WatchCaptureOwnerPresentation(
                            status: status,
                            queuedCount: counts.queued,
                            transferringCount: counts.transferring,
                            confirmingCount: counts.confirming,
                            handedOffCount: counts.handedOff
                        ),
                        isReachable: isReachable
                    )
                    XCTAssertTrue(allowed.contains(model.stateColorRole))
                    if let role = model.compactHandoff?.role {
                        XCTAssertTrue(allowed.contains(role))
                    }

                    var visibleStrings = [
                        model.stateWord,
                        model.trustLine,
                        model.linkLine,
                        model.compactHandoff?.line,
                        model.compactHandoff?.subtext,
                    ].compactMap(\.self)
                    visibleStrings.append(contentsOf: model.detailRows.map(\.label))

                    for string in visibleStrings {
                        let normalized = string.lowercased()
                        XCTAssertFalse(normalized.contains("green"))
                        XCTAssertFalse(normalized.contains("in your journal"))
                    }
                }
            }
        }
    }

    func testInferredTerminalNeverClaimsDetectionForAnyReason() {
        for reason in WatchCaptureTerminalReason.allCases {
            XCTAssertEqual(
                reason.observerError(disposition: .inferredStoppedItself).message,
                SourceVocabulary.watchNoticeAudioCouldNotBeConfirmedTitle
            )
            XCTAssertNotEqual(
                reason.observerError(disposition: .detectedStoppedItself).message,
                SourceVocabulary.watchNoticeAudioCouldNotBeConfirmedTitle,
                "detected disposition must retain its existing mapping for \(reason.rawValue)"
            )
        }
    }
}
