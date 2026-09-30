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
            fetchResult: { _ in
                fetchCalled.withLock { $0 = true }
                return .match(.uiTestSample)
            }
        )

        XCTAssertEqual(outcome, .fallback(.timeout))
        XCTAssertFalse(fetchCalled.withLock { $0 })
    }

    @MainActor
    func testResolveConfirmationFallsBackWhenFetcherReturnsMissingOrInvalid() async {
        let outcome = await resolveConfirmation(
            timeout: .milliseconds(20),
            step: .milliseconds(5),
            connectedPort: { 7071 },
            fetchResult: { _ in .missingOrInvalid }
        )

        XCTAssertEqual(outcome, .fallback(.missingOrInvalidMark))
    }

    @MainActor
    func testResolveConfirmationReturnsConfirmForValidMark() async {
        let outcome = await resolveConfirmation(
            timeout: .milliseconds(20),
            step: .milliseconds(5),
            connectedPort: { 7071 },
            fetchResult: { _ in .match(.uiTestSample) }
        )

        XCTAssertEqual(outcome, .confirm(.uiTestSample))
    }

    @MainActor
    func testResolveConfirmationRetriesOnInstanceMismatchUntilTimeout() async {
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)
        let outcome = await resolveConfirmation(
            timeout: .milliseconds(30),
            step: .milliseconds(5),
            connectedPort: { 7071 },
            fetchResult: { _ in
                fetchCount.withLock { $0 += 1 }
                return .instanceMismatch
            }
        )

        XCTAssertEqual(outcome, .fallback(.timeout))
        XCTAssertGreaterThan(fetchCount.withLock { $0 }, 1)
    }

    @MainActor
    func testResolveConfirmationSucceedsAfterInstanceMismatch() async {
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)
        let outcome = await resolveConfirmation(
            timeout: .milliseconds(100),
            step: .milliseconds(5),
            connectedPort: { 7071 },
            fetchResult: { _ in
                let count = fetchCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 1 {
                    return .instanceMismatch
                }
                return .match(.uiTestSample)
            }
        )

        XCTAssertEqual(outcome, .confirm(.uiTestSample))
        XCTAssertEqual(fetchCount.withLock { $0 }, 2)
    }

    @MainActor
    func testResolveConfirmationWithStartDeadlineWhenConnectedStartsDeadlineOnlyWhenConnected() async {
        var isConnected = false
        let clock = ContinuousClock()
        let start = clock.now

        let outcome = await resolveConfirmation(
            timeout: .milliseconds(50),
            step: .milliseconds(10),
            startDeadlineWhenConnected: true,
            connectedPort: {
                if !isConnected {
                    if clock.now - start > .milliseconds(40) {
                        isConnected = true
                    }
                    return nil
                }
                return 7071
            },
            fetchResult: { _ in
                .match(.uiTestSample)
            }
        )

        XCTAssertEqual(outcome, .confirm(.uiTestSample))
        XCTAssertTrue(clock.now - start >= .milliseconds(40))
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
                fetchResult: { _ in
                    fetchStarted.withLock { $0 = true }
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        fetchCancelled.withLock { $0 = true }
                        return .missingOrInvalid
                    }
                    return .match(.uiTestSample)
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
