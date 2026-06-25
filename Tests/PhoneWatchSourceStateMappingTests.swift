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
            (.appInstalled, .active, nil),
        ]

        for (install, expectedState, expectedAttention) in cases {
            let mapped = phoneWatchSourceState(
                install: install,
                recordingStatus: .observing
            )

            XCTAssertEqual(mapped.0, expectedState)
            XCTAssertEqual(mapped.1, expectedAttention)
        }
    }

    func testWatchInstallStateDerivation() {
        XCTAssertEqual(
            watchInstallState(
                isSupported: false,
                isPaired: true,
                isWatchAppInstalled: true,
                activationState: .activated
            ),
            .notSupported
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: false,
                isWatchAppInstalled: true,
                activationState: .activated
            ),
            .noWatchPaired
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: false,
                activationState: .activated
            ),
            .pairedNoApp
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                activationState: .inactive
            ),
            .pairedNoApp
        )
        XCTAssertEqual(
            watchInstallState(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                activationState: .activated
            ),
            .appInstalled
        )
    }

    func testRecordingStatusFromContext() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(watchRecordingStatus(context: nil, now: now), .noContext)
        XCTAssertEqual(
            watchRecordingStatus(
                context: Self.context(phase: .observing, asOf: now.addingTimeInterval(-44)),
                now: now
            ),
            .observing
        )
        XCTAssertEqual(
            watchRecordingStatus(
                context: Self.context(phase: .observing, asOf: now.addingTimeInterval(-45)),
                now: now
            ),
            .idle
        )
        XCTAssertEqual(
            watchRecordingStatus(context: Self.context(phase: .idle, asOf: now), now: now),
            .idle
        )
        XCTAssertEqual(
            watchRecordingStatus(context: Self.context(phase: .stopping, asOf: now), now: now),
            .idle
        )
    }

    func testFutureAsOfClampsThenAgesOut() {
        let context = Self.context(
            phase: .observing,
            asOf: Date(timeIntervalSince1970: 1_030)
        )

        XCTAssertEqual(
            watchRecordingStatus(context: context, now: Date(timeIntervalSince1970: 1_000)),
            .observing
        )
        XCTAssertEqual(
            watchRecordingStatus(context: context, now: Date(timeIntervalSince1970: 1_075)),
            .idle
        )
    }

    func testPresentationCopyForInstalledWatch() {
        let observing = phoneWatchSourcePresentation(install: .appInstalled, recordingStatus: .observing)
        XCTAssertEqual(observing.state, .active)
        XCTAssertNil(observing.attention)
        XCTAssertEqual(observing.subtext, SourceVocabulary.watchListeningSubtext)

        let idle = phoneWatchSourcePresentation(install: .appInstalled, recordingStatus: .idle)
        XCTAssertEqual(idle.state, .off)
        XCTAssertNil(idle.attention)
        XCTAssertEqual(idle.subtext, SourceVocabulary.watchIdleSubtext)

        let noContext = phoneWatchSourcePresentation(install: .appInstalled, recordingStatus: .noContext)
        XCTAssertEqual(noContext.state, .off)
        XCTAssertNil(noContext.attention)
        XCTAssertEqual(noContext.subtext, SourceVocabulary.watchNoContextSubtext)
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
            seq: 1
        )
    }
}
