// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
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
    private func yieldToMainActor() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}
