// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class WatchLinkTests: XCTestCase {
    @MainActor private lazy var session = MockWatchConnectivitySession()

    @MainActor
    func testActivateInvokesSessionActivation() async {
        let watchLink = WatchLink(session: self.session)

        watchLink.activate()
        await self.yieldToMainActor()

        XCTAssertEqual(self.session.activateCallCount, 1)
    }

    @MainActor
    func testReachabilityTransitionIsSurfaced() async {
        let watchLink = WatchLink(session: self.session)
        XCTAssertEqual(watchLink.isReachable, false)

        self.session.emitReachability(true)
        await self.yieldToMainActor()
        XCTAssertEqual(watchLink.isReachable, true)

        self.session.emitReachability(false)
        await self.yieldToMainActor()
        XCTAssertEqual(watchLink.isReachable, false)
    }

    @MainActor
    private func yieldToMainActor() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}
