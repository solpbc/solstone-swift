// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest
import os

nonisolated final class PairFlowConfirmationTests: XCTestCase {
    @MainActor
    func testResolveConfirmationFallsBackOnConnectedPortTimeout() async {
        let fetchCalled = OSAllocatedUnfairLock(initialState: false)

        let outcome = await resolveConfirmation(
            timeout: .milliseconds(20),
            step: .milliseconds(5),
            connectedPort: { nil },
            fetchMark: { _ in
                fetchCalled.withLock { $0 = true }
                return .uiTestSample
            }
        )

        XCTAssertEqual(outcome, .fallback(.timeout))
        XCTAssertFalse(fetchCalled.withLock { $0 })
    }

    @MainActor
    func testResolveConfirmationFallsBackWhenFetcherReturnsNil() async {
        let outcome = await resolveConfirmation(
            timeout: .milliseconds(20),
            step: .milliseconds(5),
            connectedPort: { 7071 },
            fetchMark: { _ in nil }
        )

        XCTAssertEqual(outcome, .fallback(.missingOrInvalidMark))
    }

    @MainActor
    func testResolveConfirmationReturnsConfirmForValidMark() async {
        let outcome = await resolveConfirmation(
            timeout: .milliseconds(20),
            step: .milliseconds(5),
            connectedPort: { 7071 },
            fetchMark: { _ in .uiTestSample }
        )

        XCTAssertEqual(outcome, .confirm(.uiTestSample))
    }

    @MainActor
    func testCompletionGateFiresOnceAcrossRepeatedCompletionAttempts() {
        let gate = PairFlowCompletionGate()
        var count = 0

        gate.completeOnce {
            count += 1
        }
        gate.completeOnce {
            count += 1
        }

        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testResolveConfirmationCancelsInFlightFetch() async {
        let fetchStarted = OSAllocatedUnfairLock(initialState: false)
        let fetchCancelled = OSAllocatedUnfairLock(initialState: false)

        let task = Task { @MainActor in
            await resolveConfirmation(
                timeout: .seconds(1),
                step: .milliseconds(5),
                connectedPort: { 7071 },
                fetchMark: { _ in
                    fetchStarted.withLock { $0 = true }
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        fetchCancelled.withLock { $0 = true }
                        return nil
                    }
                    return .uiTestSample
                }
            )
        }

        while !fetchStarted.withLock({ $0 }) {
            await Task.yield()
        }

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .fallback(.cancelled))
        XCTAssertTrue(fetchCancelled.withLock { $0 })
    }
}
