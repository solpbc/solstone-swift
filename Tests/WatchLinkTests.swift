// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class WatchLinkTests: XCTestCase {
    @MainActor private lazy var session = MockWatchConnectivitySession()

    @MainActor
    func testWatchStateIsSurfacedAtInit() {
        self.session.isSupported = true
        self.session.isPaired = true
        self.session.isWatchAppInstalled = true
        self.session.activationState = .activated

        let watchLink = WatchLink(session: self.session, receiver: nil)

        XCTAssertTrue(watchLink.isSupported)
        XCTAssertTrue(watchLink.isPaired)
        XCTAssertTrue(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .activated)
    }

    @MainActor
    func testActivateInvokesSessionActivation() async {
        let watchLink = WatchLink(session: self.session, receiver: nil)

        watchLink.activate()
        await self.yieldToMainActor()

        XCTAssertEqual(self.session.activateCallCount, 1)
    }

    @MainActor
    func testActivationRefreshesWatchState() async {
        let watchLink = WatchLink(session: self.session, receiver: nil)

        watchLink.activate()
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.activationState, .activated)
    }

    @MainActor
    func testReachabilityTransitionIsSurfaced() async {
        let watchLink = WatchLink(session: self.session, receiver: nil)
        XCTAssertEqual(watchLink.isReachable, false)

        self.session.emitReachability(true)
        await self.yieldToMainActor()
        XCTAssertEqual(watchLink.isReachable, true)

        self.session.emitReachability(false)
        await self.yieldToMainActor()
        XCTAssertEqual(watchLink.isReachable, false)
    }

    @MainActor
    func testWatchStateTransitionIsSurfaced() async {
        let watchLink = WatchLink(session: self.session, receiver: nil)
        XCTAssertFalse(watchLink.isPaired)
        XCTAssertFalse(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .notActivated)

        self.session.emitWatchState(
            isPaired: true,
            isWatchAppInstalled: true,
            activationState: .activated
        )
        await self.yieldToMainActor()

        XCTAssertTrue(watchLink.isPaired)
        XCTAssertTrue(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .activated)

        self.session.emitWatchState(
            isPaired: true,
            isWatchAppInstalled: false,
            activationState: .inactive
        )
        await self.yieldToMainActor()

        XCTAssertTrue(watchLink.isPaired)
        XCTAssertFalse(watchLink.isWatchAppInstalled)
        XCTAssertEqual(watchLink.activationState, .inactive)
    }

    @MainActor
    func testDeliveredApplicationContextUpdatesWatchStatus() async {
        let watchLink = WatchLink(session: self.session, receiver: nil)
        let status = Self.status(seq: 1)

        self.session.deliverApplicationContext(status.applicationContext())
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.watchStatus, status)
    }

    @MainActor
    func testActivateRecoversReceivedApplicationContext() async {
        let status = Self.status(seq: 2)
        self.session.receivedApplicationContext = status.applicationContext()
        let watchLink = WatchLink(session: self.session, receiver: nil)

        watchLink.activate()
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.watchStatus, status)
        XCTAssertEqual(
            watchRecordingStatus(
                context: watchLink.watchStatus,
                now: Date(timeIntervalSince1970: 1_020)
            ),
            .observing
        )
    }

    @MainActor
    func testReachabilityDoesNotAffectWatchStatus() async {
        let status = Self.status(seq: 3)
        let watchLink = WatchLink(session: self.session, receiver: nil)
        self.session.deliverApplicationContext(status.applicationContext())
        await self.yieldToMainActor()

        self.session.emitReachability(true)
        await self.yieldToMainActor()
        self.session.emitReachability(false)
        await self.yieldToMainActor()

        XCTAssertEqual(watchLink.watchStatus, status)
    }

    @MainActor
    func testReachabilityCannotMakeMissingContextObserving() {
        self.session.isSupported = true
        self.session.isPaired = true
        self.session.isWatchAppInstalled = true
        self.session.activationState = .activated
        self.session.isReachable = true
        let watchLink = WatchLink(session: self.session, receiver: nil)

        let recordingStatus = watchRecordingStatus(
            context: watchLink.watchStatus,
            now: Date(timeIntervalSince1970: 1_020)
        )
        let presentation = phoneWatchSourcePresentation(
            install: watchInstallState(
                isSupported: watchLink.isSupported,
                isPaired: watchLink.isPaired,
                isWatchAppInstalled: watchLink.isWatchAppInstalled,
                activationState: watchLink.activationState
            ),
            recordingStatus: recordingStatus
        )

        XCTAssertEqual(recordingStatus, .noContext)
        XCTAssertEqual(presentation.state, .off)
    }

    @MainActor
    private func yieldToMainActor() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    private static func status(seq: Int) -> WatchStatusContext {
        WatchStatusContext(
            phase: .observing,
            sessionID: "session-\(seq)",
            startedAt: Date(timeIntervalSince1970: 1_000),
            asOf: Date(timeIntervalSince1970: 1_015),
            seq: seq
        )
    }
}
