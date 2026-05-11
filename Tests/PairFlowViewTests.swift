// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class PairFlowViewTests: XCTestCase {
    @MainActor
    func testFallbackTimerSurfacesCodeAffordanceAfterDelay() async {
        let timer = PairFlowFallbackTimer(delay: .milliseconds(20))

        timer.start()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(timer.shouldShowCodeFallback)
    }

    @MainActor
    func testFallbackTimerCancelPreventsAffordance() async {
        let timer = PairFlowFallbackTimer(delay: .milliseconds(40))

        timer.start()
        timer.cancel()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(timer.shouldShowCodeFallback)
    }

    @MainActor
    func testFallbackTimerResetAllowsRestart() async {
        let timer = PairFlowFallbackTimer(delay: .milliseconds(20))

        timer.start()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(timer.shouldShowCodeFallback)

        timer.reset()
        XCTAssertFalse(timer.shouldShowCodeFallback)
        timer.start()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(timer.shouldShowCodeFallback)
    }
}
