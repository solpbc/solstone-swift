// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class TransferDrainProgressTests: XCTestCase {
    func testFinishedWhenCurrentTotalIsZero() {
        XCTAssertEqual(
            evaluateDrainRound(self.input(previousTotal: 2, currentTotal: 0)),
            .finished
        )
    }

    func testProgressResetsPreviousAndStallCount() {
        XCTAssertEqual(
            evaluateDrainRound(self.input(previousTotal: 5, currentTotal: 3, stalledRounds: 1)),
            .keepGoing(previousTotal: 3, stalledRounds: 0)
        )
    }

    func testInFlightNoProgressKeepsGoing() {
        XCTAssertEqual(
            evaluateDrainRound(self.input(previousTotal: 3, currentTotal: 3, inFlight: 1, stalledRounds: 1)),
            .keepGoing(previousTotal: 3, stalledRounds: 0)
        )
    }

    func testBackoffWithLiveEndpointKeepsGoing() {
        XCTAssertEqual(
            evaluateDrainRound(self.input(
                previousTotal: 3,
                currentTotal: 3,
                stalledRounds: 1,
                backoffPendingCount: 1,
                endpointHeld: false
            )),
            .keepGoing(previousTotal: 3, stalledRounds: 0)
        )
    }

    func testBackoffWithHeldEndpointStallsAtLimit() {
        XCTAssertEqual(
            evaluateDrainRound(self.input(
                previousTotal: 3,
                currentTotal: 3,
                stalledRounds: 1,
                backoffPendingCount: 1,
                endpointHeld: true
            )),
            .stalled
        )
    }

    func testNoProgressStallsAtLimit() {
        XCTAssertEqual(
            evaluateDrainRound(self.input(previousTotal: 3, currentTotal: 3, stalledRounds: 1)),
            .stalled
        )
    }

    private func input(
        previousTotal: Int,
        currentTotal: Int,
        inFlight: Int = 0,
        stalledRounds: Int = 0,
        backoffPendingCount: Int = 0,
        endpointHeld: Bool = false
    ) -> DrainRoundInput {
        DrainRoundInput(
            previousTotal: previousTotal,
            currentTotal: currentTotal,
            inFlight: inFlight,
            stalledRounds: stalledRounds,
            backoffPendingCount: backoffPendingCount,
            endpointHeld: endpointHeld
        )
    }
}
