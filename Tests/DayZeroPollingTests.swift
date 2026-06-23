// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class DayZeroPollingTests: XCTestCase {
    func testPollDecisionTreatsNotFoundAsTerminal() {
        XCTAssertEqual(
            DayZeroOverlayView.pollDecision(for: HomeAPIError.server(status: 404, body: "missing")),
            .terminal
        )
    }

    func testPollDecisionTreatsNetworkErrorAsRetry() {
        XCTAssertEqual(
            DayZeroOverlayView.pollDecision(for: URLError(.notConnectedToInternet)),
            .retry
        )
    }

    @MainActor
    func testRunPollingTerminatesImmediatelyForNotFound() async {
        var fetchCount = 0
        var sleepCount = 0

        let result = await DayZeroOverlayView.runPolling(
            fetch: {
                fetchCount += 1
                throw HomeAPIError.server(status: 404, body: "missing")
            },
            sleep: { _ in
                sleepCount += 1
            },
            shouldContinue: {
                true
            }
        )

        XCTAssertTrue(result.isInert)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(sleepCount, 0)
    }

    @MainActor
    func testRunPollingCapsTransientFailures() async {
        var fetchCount = 0
        var sleepCount = 0

        let result = await DayZeroOverlayView.runPolling(
            fetch: {
                fetchCount += 1
                throw URLError(.timedOut)
            },
            sleep: { _ in
                sleepCount += 1
            },
            maxTransientRetries: 3,
            shouldContinue: {
                true
            }
        )

        XCTAssertTrue(result.isInert)
        XCTAssertEqual(fetchCount, 3)
        XCTAssertEqual(sleepCount, 2)
    }
}
