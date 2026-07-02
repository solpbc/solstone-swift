// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import WatchConnectivity
import XCTest

nonisolated final class PhoneWatchSourceStateMappingTests: XCTestCase {
    func testInstallStatesMapToSourceStateAndAttention() {
        let cases: [(WatchInstallState, SourceState, SourceAttention?)] = [
            (.notSupported, .off, SourceAttention(message: SourceVocabulary.watchNotSupported)),
            (.noWatchPaired, .needsAttention, SourceAttention(message: SourceVocabulary.watchNoWatchPaired)),
            (.pairedNoApp, .needsAttention, SourceAttention(message: SourceVocabulary.watchAppNotInstalled)),
            (.receivingUnconfirmedInstall, .off, nil),
            (.appInstalled, .active, nil),
        ]

        for (install, expectedState, expectedAttention) in cases {
            let mapped = phoneWatchSourceState(
                install: install,
                recordingStatus: .observing,
                isReachable: false
            )

            XCTAssertEqual(mapped.0, expectedState)
            XCTAssertEqual(mapped.1, expectedAttention)
        }
    }

    func testWatchInstallStateDerivation() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            watchInstallState(
                isSupported: false,
                isPaired: true,
                isWatchAppInstalled: true,
                activationState: .activated,
                now: now,
                lastReceivedAt: nil
            ),
            .notSupported
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: false,
                isWatchAppInstalled: true,
                activationState: .activated,
                now: now,
                lastReceivedAt: nil
            ),
            .noWatchPaired
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: false,
                activationState: .activated,
                now: now,
                lastReceivedAt: nil
            ),
            .pairedNoApp
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                activationState: .inactive,
                now: now,
                lastReceivedAt: nil
            ),
            .pairedNoApp
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                activationState: .activated,
                now: now,
                lastReceivedAt: nil
            ),
            .appInstalled
        )
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

    func testFreshReceiptCorroboratesMissingContextWithoutActivating() {
        let now = Date(timeIntervalSince1970: 1_000)

        let status = watchRecordingStatus(
            context: nil,
            now: now,
            lastReceivedAt: now.addingTimeInterval(-5)
        )
        let presentation = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: status,
            isReachable: false
        )

        XCTAssertEqual(status, .noContextButReceiving)
        XCTAssertEqual(presentation.state, .off)
        XCTAssertNil(presentation.attention)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchReceivingSubtext)
        XCTAssertNotEqual(presentation.subtext, SourceVocabulary.watchNoContextSubtext)
        XCTAssertNotEqual(presentation.state, .active)
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
            install: .appInstalled,
            recordingStatus: status,
            isReachable: false
        )

        XCTAssertEqual(status, .observing)
        XCTAssertEqual(presentation.state, .active)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchListeningSubtext)
    }

    func testReceiptCorroborationBoundaryAndCadence() {
        let base = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            watchRecordingStatus(
                context: nil,
                now: base,
                lastReceivedAt: base.addingTimeInterval(-46)
            ),
            .noContextButReceiving
        )

        for offset in stride(from: 0, through: 30, by: 5) {
            let now = base.addingTimeInterval(TimeInterval(offset))
            let trailingReceipt = now.addingTimeInterval(TimeInterval(offset.isMultiple(of: 10) ? -10 : -5))
            XCTAssertEqual(
                watchRecordingStatus(
                    context: nil,
                    now: now,
                    lastReceivedAt: trailingReceipt
                ),
                .noContextButReceiving
            )
        }

        XCTAssertEqual(
            watchRecordingStatus(
                context: nil,
                now: base,
                lastReceivedAt: base.addingTimeInterval(-61)
            ),
            .noContext
        )
    }

    func testInstallReceiptCorroborationAvoidsInstallCTAAndPairedScopeOnly() {
        let now = Date(timeIntervalSince1970: 1_000)
        let freshReceipt = now.addingTimeInterval(-5)

        let receiving = watchInstallState(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: false,
            activationState: .activated,
            now: now,
            lastReceivedAt: freshReceipt
        )
        let presentation = phoneWatchSourcePresentation(
            install: receiving,
            recordingStatus: .noContext,
            isReachable: false
        )

        XCTAssertEqual(receiving, .receivingUnconfirmedInstall)
        XCTAssertNotEqual(receiving, .pairedNoApp)
        XCTAssertNotEqual(receiving, .appInstalled)
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(install: receiving))
        XCTAssertEqual(presentation.state, .off)
        XCTAssertNil(presentation.attention)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchReceivingSubtext)

        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: false,
                isWatchAppInstalled: false,
                activationState: .activated,
                now: now,
                lastReceivedAt: freshReceipt
            ),
            .noWatchPaired
        )
    }

    func testPresentationCopyForInstalledWatch() {
        let observing = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: .observing,
            isReachable: false
        )
        XCTAssertEqual(observing.state, .active)
        XCTAssertNil(observing.attention)
        XCTAssertEqual(observing.subtext, SourceVocabulary.watchListeningSubtext)

        let idle = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: .idle,
            isReachable: false
        )
        XCTAssertEqual(idle.state, .off)
        XCTAssertNil(idle.attention)
        XCTAssertEqual(idle.subtext, SourceVocabulary.watchIdleSubtext)

        let noContext = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: .noContext,
            isReachable: false
        )
        XCTAssertEqual(noContext.state, .off)
        XCTAssertNil(noContext.attention)
        XCTAssertEqual(noContext.subtext, SourceVocabulary.watchNoContextSubtext)

        let receiving = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: .noContextButReceiving,
            isReachable: false
        )
        XCTAssertEqual(receiving.state, .off)
        XCTAssertNil(receiving.attention)
        XCTAssertEqual(receiving.subtext, SourceVocabulary.watchReceivingSubtext)
    }

    func testReachableInstalledIdleUsesConnectedNowCopy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let install = watchInstallState(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: true,
            activationState: .activated,
            now: now,
            lastReceivedAt: nil
        )
        let status = watchRecordingStatus(
            context: Self.context(phase: .idle, asOf: now),
            now: now,
            lastReceivedAt: nil
        )

        let presentation = phoneWatchSourcePresentation(
            install: install,
            recordingStatus: status,
            isReachable: true
        )

        XCTAssertEqual(install, .appInstalled)
        XCTAssertEqual(status, .idle)
        XCTAssertEqual(presentation.state, .off)
        XCTAssertNil(presentation.attention)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchConnectedNowSubtext)
    }

    func testReachableInstalledNoContextStaysOffWithConnectedNowCopy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let install = watchInstallState(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: true,
            activationState: .activated,
            now: now,
            lastReceivedAt: nil
        )
        let status = watchRecordingStatus(context: nil, now: now, lastReceivedAt: nil)

        let presentation = phoneWatchSourcePresentation(
            install: install,
            recordingStatus: status,
            isReachable: true
        )

        XCTAssertEqual(install, .appInstalled)
        XCTAssertEqual(status, .noContext)
        XCTAssertEqual(presentation.state, .off)
        XCTAssertNil(presentation.attention)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchConnectedNowSubtext)
    }

    func testReachableStaleObservingUsesConnectedNowIdleCopy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let status = watchRecordingStatus(
            context: Self.context(phase: .observing, asOf: now.addingTimeInterval(-45)),
            now: now,
            lastReceivedAt: nil
        )

        let presentation = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: status,
            isReachable: true
        )

        XCTAssertEqual(status, .idle)
        XCTAssertEqual(presentation.state, .off)
        XCTAssertNil(presentation.attention)
        XCTAssertEqual(presentation.subtext, SourceVocabulary.watchConnectedNowSubtext)
    }

    func testReachabilityDoesNotOverrideReceivingObservingOrInstallState() {
        let receiving = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: .noContextButReceiving,
            isReachable: true
        )
        XCTAssertEqual(receiving.state, .off)
        XCTAssertNil(receiving.attention)
        XCTAssertEqual(receiving.subtext, SourceVocabulary.watchReceivingSubtext)

        let observing = phoneWatchSourcePresentation(
            install: .appInstalled,
            recordingStatus: .observing,
            isReachable: true
        )
        XCTAssertEqual(observing.state, .active)
        XCTAssertNil(observing.attention)
        XCTAssertEqual(observing.subtext, SourceVocabulary.watchListeningSubtext)

        let reachablePairedNoApp = phoneWatchSourcePresentation(
            install: .pairedNoApp,
            recordingStatus: .noContext,
            isReachable: true
        )
        let notReachablePairedNoApp = phoneWatchSourcePresentation(
            install: .pairedNoApp,
            recordingStatus: .noContext,
            isReachable: false
        )
        XCTAssertEqual(reachablePairedNoApp, notReachablePairedNoApp)
    }
}

private extension PhoneWatchSourceStateMappingTests {
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
