// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import WatchConnectivity
import XCTest

nonisolated final class PhoneWatchSourceStateMappingTests: XCTestCase {
    func testReadinessDoesNotConsultActivatedFactsUntilActivatedAndRecomputesOnExit() {
        XCTAssertEqual(
            watchSessionReadiness(
                isSupported: true,
                activationState: .notActivated,
                activationFailed: false,
                activatedReadiness: Self.crashIfConsulted
            ),
            .checking
        )
        XCTAssertEqual(
            watchSessionReadiness(
                isSupported: true,
                activationState: .inactive,
                activationFailed: false,
                activatedReadiness: Self.crashIfConsulted
            ),
            .checking
        )

        let activated = watchSessionReadiness(
            isSupported: true,
            activationState: .activated,
            activationFailed: false
        ) {
            .installedNeverOpened
        }

        XCTAssertEqual(activated, .activated(.installedNeverOpened))
        XCTAssertEqual(
            phoneWatchSourceLane(
                session: activated,
                flow: Self.flow(recordingStatus: .noContext)
            ),
            .installedNeverOpened
        )
    }

    func testActivationFailedIsDistinctFromChecking() {
        let readiness = watchSessionReadiness(
            isSupported: true,
            activationState: .inactive,
            activationFailed: true,
            activatedReadiness: Self.crashIfConsulted
        )
        let presentation = phoneWatchSourcePresentation(
            lane: phoneWatchSourceLane(
                session: readiness,
                flow: Self.flow(recordingStatus: .observing)
            )
        )

        XCTAssertEqual(readiness, .activationFailed)
        XCTAssertEqual(presentation.state, .off)
        XCTAssertNil(presentation.attention)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchActivationFailedSubtext)
    }

    func testActivatedReadinessSetupLogic() {
        XCTAssertEqual(
            watchActivatedReadiness(
                isPaired: false,
                isWatchAppInstalled: true,
                facts: Self.facts()
            ),
            .noWatchPaired
        )
        XCTAssertEqual(
            watchActivatedReadiness(
                isPaired: true,
                isWatchAppInstalled: false,
                facts: Self.facts()
            ),
            .readyToSetUp(.installApp)
        )
        XCTAssertEqual(
            watchActivatedReadiness(
                isPaired: true,
                isWatchAppInstalled: true,
                facts: Self.facts()
            ),
            .installedNeverOpened
        )
        XCTAssertEqual(
            watchActivatedReadiness(
                isPaired: true,
                isWatchAppInstalled: false,
                facts: Self.facts(watchAppCheckedIn: true)
            ),
            .installedActive
        )
        XCTAssertEqual(
            watchActivatedReadiness(
                isPaired: true,
                isWatchAppInstalled: false,
                facts: Self.facts(segmentFileReceived: true)
            ),
            .installedActive
        )
    }

    func testLanePresentationMatrixUsesReviewedCopy() {
        let cases: [(PhoneWatchSourceLane, SourceState, String?, SourceAttention?)] = [
            (.unsupported, .off, nil, nil),
            (.checking, .checking, nil, nil),
            (.activationFailed, .off, SourceVocabulary.watchActivationFailedSubtext, nil),
            (.noWatchPaired, .off, SourceVocabulary.watchNoWatchPairedSubtext, nil),
            (.readyToSetUp(.installApp), .readyToSetUp, SourceVocabulary.watchReadyToSetUpSubtext, nil),
            (.installedNeverOpened, .enrolling, SourceVocabulary.watchInstalledNeverOpenedSubtext, nil),
            (.installedActive(.observing), .active, SourceVocabulary.watchListeningSubtext, nil),
            (.installedActive(.receiving), .active, SourceVocabulary.watchReceivingNowSubtext, nil),
            (.installedActive(.waiting(Self.waiting(count: 2))), .off, SourceVocabulary.watchWaitingToSyncFromWatch(2), nil),
            (.installedActive(.idle), .off, SourceVocabulary.watchIdleNowSubtext, nil),
        ]

        for (lane, expectedState, expectedSubtext, expectedAttention) in cases {
            let presentation = phoneWatchSourcePresentation(lane: lane)
            XCTAssertEqual(presentation.state, expectedState, "\(lane)")
            XCTAssertEqual(presentation.subtext, expectedSubtext, "\(lane)")
            XCTAssertEqual(presentation.attention, expectedAttention, "\(lane)")
        }

        let stuck = phoneWatchSourcePresentation(lane: .installedActive(.stuck(.handoff)))
        XCTAssertEqual(stuck.state, .needsAttention)
        XCTAssertEqual(stuck.subtext, SourceVocabulary.watchPipelineHandoffStuckReason)
        XCTAssertEqual(stuck.attention, SourceAttention(message: SourceVocabulary.watchPipelineHandoffStuckReason))
    }

    func testInstalledFlowPrecedenceMatrix() {
        let waiting = Self.waiting(count: 2)

        XCTAssertEqual(
            watchInstalledFlow(Self.flow(stuck: .relay, recordingStatus: .observing, waiting: waiting)),
            .stuck(.relay)
        )
        XCTAssertEqual(
            watchInstalledFlow(Self.flow(recordingStatus: .observing, waiting: waiting)),
            .observing
        )
        XCTAssertEqual(
            watchInstalledFlow(Self.flow(recordingStatus: .noContextButReceiving, waiting: waiting)),
            .receiving
        )
        XCTAssertEqual(
            watchInstalledFlow(Self.flow(recordingStatus: .idle, waiting: waiting)),
            .waiting(waiting)
        )
        XCTAssertEqual(
            watchInstalledFlow(Self.flow(recordingStatus: .idle, waiting: Self.waiting(count: 0))),
            .idle
        )
    }

    func testRetryableBacklogRendersCalmWaitingAndStuckRendersReason() {
        let waitingPresentation = phoneWatchSourcePresentation(
            lane: .installedActive(.waiting(Self.waiting(count: 1)))
        )
        XCTAssertEqual(waitingPresentation.state, .off)
        XCTAssertNil(waitingPresentation.attention)
        XCTAssertEqual(waitingPresentation.subtext, "1 waiting to sync from your watch")

        let stuckPresentation = phoneWatchSourcePresentation(lane: .installedActive(.stuck(.orphan)))
        XCTAssertEqual(stuckPresentation.state, .needsAttention)
        XCTAssertEqual(stuckPresentation.subtext, SourceVocabulary.watchPipelineOrphanStuckReason)
        XCTAssertEqual(
            stuckPresentation.attention,
            SourceAttention(message: SourceVocabulary.watchPipelineOrphanStuckReason)
        )
    }

    func testWatchRowPresentationNeverFallsThroughToGenericAttentionCopy() {
        let lanes: [PhoneWatchSourceLane] = [
            .unsupported,
            .checking,
            .activationFailed,
            .noWatchPaired,
            .readyToSetUp(.installApp),
            .installedNeverOpened,
            .installedActive(.stuck(.relay)),
            .installedActive(.stuck(.handoff)),
            .installedActive(.stuck(.orphan)),
            .installedActive(.observing),
            .installedActive(.receiving),
            .installedActive(.waiting(Self.waiting(count: 2))),
            .installedActive(.idle),
        ]

        for lane in lanes {
            let presentation = phoneWatchSourcePresentation(lane: lane)
            XCTAssertNotEqual(presentation.subtext, SourceVocabulary.needsAttentionSubtext, "\(lane)")
            XCTAssertNotEqual(presentation.attention?.message, SourceVocabulary.needsAttentionSubtext, "\(lane)")
        }
    }

    func testRecordingStatusFromContext() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(watchRecordingStatus(context: nil, now: now, lastReceivedAt: nil), .noContext)
        XCTAssertEqual(
            watchRecordingStatus(
                context: Self.context(phase: .observing, asOf: now.addingTimeInterval(-44)),
                now: now,
                lastReceivedAt: nil
            ),
            .observing
        )
        XCTAssertEqual(
            watchRecordingStatus(
                context: Self.context(phase: .observing, asOf: now.addingTimeInterval(-45)),
                now: now,
                lastReceivedAt: nil
            ),
            .idle
        )
        XCTAssertEqual(
            watchRecordingStatus(
                context: Self.context(phase: .idle, asOf: now),
                now: now,
                lastReceivedAt: nil
            ),
            .idle
        )
        XCTAssertEqual(
            watchRecordingStatus(
                context: Self.context(phase: .stopping, asOf: now),
                now: now,
                lastReceivedAt: nil
            ),
            .idle
        )
    }

    func testFutureAsOfClampsThenAgesOut() {
        let context = Self.context(
            phase: .observing,
            asOf: Date(timeIntervalSince1970: 1_030)
        )

        XCTAssertEqual(
            watchRecordingStatus(
                context: context,
                now: Date(timeIntervalSince1970: 1_000),
                lastReceivedAt: nil
            ),
            .observing
        )
        XCTAssertEqual(
            watchRecordingStatus(
                context: context,
                now: Date(timeIntervalSince1970: 1_075),
                lastReceivedAt: nil
            ),
            .idle
        )
    }

    func testFreshReceiptCorroboratesMissingContextAsReceiving() {
        let now = Date(timeIntervalSince1970: 1_000)

        let status = watchRecordingStatus(
            context: nil,
            now: now,
            lastReceivedAt: now.addingTimeInterval(-5)
        )
        let presentation = phoneWatchSourcePresentation(
            lane: .installedActive(watchInstalledFlow(Self.flow(recordingStatus: status)))
        )

        XCTAssertEqual(status, .noContextButReceiving)
        XCTAssertEqual(presentation.state, .active)
        XCTAssertNil(presentation.attention)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchReceivingNowSubtext)
        XCTAssertNotEqual(presentation.subtext, SourceVocabulary.watchListeningSubtext)
    }

    func testStaleOrMissingReceiptKeepsMissingContext() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            watchRecordingStatus(
                context: nil,
                now: now,
                lastReceivedAt: now.addingTimeInterval(-61)
            ),
            .noContext
        )
        XCTAssertEqual(
            watchRecordingStatus(context: nil, now: now, lastReceivedAt: nil),
            .noContext
        )
    }

    func testReceiptDoesNotReplaceFreshObservingContext() {
        let now = Date(timeIntervalSince1970: 1_000)

        let status = watchRecordingStatus(
            context: Self.context(phase: .observing, asOf: now.addingTimeInterval(-5)),
            now: now,
            lastReceivedAt: now.addingTimeInterval(-5)
        )
        let presentation = phoneWatchSourcePresentation(
            lane: .installedActive(watchInstalledFlow(Self.flow(recordingStatus: status)))
        )

        XCTAssertEqual(status, .observing)
        XCTAssertEqual(presentation.state, .active)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchListeningSubtext)
    }
}

private extension PhoneWatchSourceStateMappingTests {
    static func crashIfConsulted() -> WatchActivatedReadiness {
        fatalError("activated readiness should not be consulted before activation")
    }

    static func facts(
        watchAppCheckedIn: Bool = false,
        segmentFileReceived: Bool = false
    ) -> WatchSourceFacts.Snapshot {
        WatchSourceFacts.Snapshot(
            watchAppCheckedIn: watchAppCheckedIn,
            segmentFileReceived: segmentFileReceived
        )
    }

    static func flow(
        stuck: WatchPipelineStuck = .none,
        recordingStatus: WatchRecordingStatus,
        waiting: WatchWaitingBreakdown = waiting(count: 0)
    ) -> WatchInstalledFlowInput {
        WatchInstalledFlowInput(stuck: stuck, recordingStatus: recordingStatus, waiting: waiting)
    }

    static func waiting(count: Int) -> WatchWaitingBreakdown {
        let phone = PhoneSideWaiting(count: count)
        return WatchWaitingBreakdown(
            watch: WatchSideWaiting(count: 0, freshness: .unknown),
            phone: phone,
            leading: count > 0 ? .phone(count: count) : nil
        )
    }

    static func context(
        phase: WatchStatusContext.Phase,
        asOf: Date
    ) -> WatchStatusContext {
        WatchStatusContext(
            phase: phase,
            sessionID: phase == .idle ? nil : "session-1",
            startedAt: phase == .idle ? nil : Date(timeIntervalSince1970: 900),
            asOf: asOf,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0
        )
    }
}
