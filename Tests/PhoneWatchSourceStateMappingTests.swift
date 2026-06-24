// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import WatchConnectivity
import XCTest

nonisolated final class PhoneWatchSourceStateMappingTests: XCTestCase {
    func testDisabledAlwaysMapsOff() {
        let installs: [WatchInstallState] = [
            .notSupported,
            .noWatchPaired,
            .pairedNoApp,
            .appInstalled,
        ]

        for install in installs {
            let mapped = phoneWatchSourceState(install: install, observing: true, enabled: false)

            XCTAssertEqual(mapped.0, .off)
            XCTAssertNil(mapped.1)
        }
    }

    func testInstallStatesMapToSourceStateAndAttention() {
        let cases: [(WatchInstallState, Bool, SourceState, SourceAttention?)] = [
            (.notSupported, false, .off, SourceAttention(message: SourceVocabulary.watchNotSupported)),
            (.notSupported, true, .off, SourceAttention(message: SourceVocabulary.watchNotSupported)),
            (.noWatchPaired, false, .needsAttention, SourceAttention(message: SourceVocabulary.watchNoWatchPaired)),
            (.noWatchPaired, true, .needsAttention, SourceAttention(message: SourceVocabulary.watchNoWatchPaired)),
            (.pairedNoApp, false, .needsAttention, SourceAttention(message: SourceVocabulary.watchAppNotInstalled)),
            (.pairedNoApp, true, .needsAttention, SourceAttention(message: SourceVocabulary.watchAppNotInstalled)),
            (.appInstalled, false, .off, nil),
            (.appInstalled, true, .active, nil),
        ]

        for (install, observing, expectedState, expectedAttention) in cases {
            let mapped = phoneWatchSourceState(install: install, observing: observing, enabled: true)

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

    func testWatchObservingWindow() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(isWatchObserving(lastReceivedAt: nil, now: now))
        XCTAssertTrue(isWatchObserving(lastReceivedAt: now.addingTimeInterval(-119), now: now))
        XCTAssertTrue(isWatchObserving(lastReceivedAt: now.addingTimeInterval(-120), now: now))
        XCTAssertFalse(isWatchObserving(lastReceivedAt: now.addingTimeInterval(-121), now: now))
        XCTAssertFalse(isWatchObserving(lastReceivedAt: now.addingTimeInterval(-1), now: now, window: 0))
    }
}
