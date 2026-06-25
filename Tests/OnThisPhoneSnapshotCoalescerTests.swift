// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class OnThisPhoneSnapshotCoalescerTests: XCTestCase {
    func testBurstSchedulesOnlyOnePerformPerWindow() async throws {
        let gate = CoalescerSleepGate()
        let coalescer = OnThisPhoneSnapshotCoalescer(sleep: { duration in
            await gate.sleep(duration)
        })
        var performCount = 0

        coalescer.schedule { performCount += 1 }
        for _ in 0..<10 {
            coalescer.schedule { performCount += 1 }
        }

        try await self.waitFor("pending coalesced sleep") {
            gate.pendingCount == 1
        }
        XCTAssertEqual(performCount, 0)

        gate.fireNext()

        try await self.waitFor("coalesced perform") {
            performCount == 1
        }
        XCTAssertEqual(performCount, 1)
    }

    func testCoalescedPerformReadsLatestState() async throws {
        let gate = CoalescerSleepGate()
        let coalescer = OnThisPhoneSnapshotCoalescer(sleep: { duration in
            await gate.sleep(duration)
        })
        var pendingCount = 3
        var observed: [Int] = []

        coalescer.schedule { observed.append(pendingCount) }
        pendingCount = 2
        coalescer.schedule { observed.append(pendingCount) }
        pendingCount = 0

        try await self.waitFor("pending latest sleep") {
            gate.pendingCount == 1
        }
        gate.fireNext()

        try await self.waitFor("latest perform") {
            observed == [0]
        }
    }

    func testSequentialWindowsEachPerformOnce() async throws {
        let gate = CoalescerSleepGate()
        let coalescer = OnThisPhoneSnapshotCoalescer(sleep: { duration in
            await gate.sleep(duration)
        })
        var performCount = 0

        coalescer.schedule { performCount += 1 }
        try await self.waitFor("first sleep") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("first perform") {
            performCount == 1
        }

        coalescer.schedule { performCount += 1 }
        try await self.waitFor("second sleep") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("second perform") {
            performCount == 2
        }
    }

    func testCancelPreventsPendingPerformAndAllowsFutureWindow() async throws {
        let gate = CoalescerSleepGate()
        let coalescer = OnThisPhoneSnapshotCoalescer(sleep: { duration in
            await gate.sleep(duration)
        })
        var performCount = 0

        coalescer.schedule { performCount += 1 }
        try await self.waitFor("cancel sleep") {
            gate.pendingCount == 1
        }
        coalescer.cancel()
        gate.fireNext()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(performCount, 0)

        coalescer.schedule { performCount += 1 }
        try await self.waitFor("post-cancel sleep") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("post-cancel perform") {
            performCount == 1
        }
    }

    func testCoalescedFailedSourceAssignmentPublishesFreshAggregate() async throws {
        let gate = CoalescerSleepGate()
        let coalescer = OnThisPhoneSnapshotCoalescer(sleep: { duration in
            await gate.sleep(duration)
        })
        var assigned = OnThisPhoneAggregateSnapshot(sources: [], items: [])
        let failedAggregate = OnThisPhoneAggregateSnapshot(
            sources: [
                OnThisPhoneSourceSnapshot(sourceKind: .share, result: .failed),
            ],
            items: []
        )

        coalescer.schedule {
            assigned = failedAggregate
        }
        try await self.waitFor("failed aggregate sleep") {
            gate.pendingCount == 1
        }
        gate.fireNext()

        try await self.waitFor("failed aggregate assignment") {
            assigned.failedSourceCount == 1
        }
        XCTAssertEqual(assigned, failedAggregate)
    }

    private func waitFor(
        _ label: String,
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private final class CoalescerSleepGate: @unchecked Sendable {
    private let continuations = OSAllocatedUnfairLock<[CheckedContinuation<Void, Never>]>(initialState: [])

    var pendingCount: Int {
        self.continuations.withLock { $0.count }
    }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            self.continuations.withLock { $0.append(continuation) }
        }
    }

    func fireNext() {
        let continuation = self.continuations.withLock { continuations -> CheckedContinuation<Void, Never>? in
            guard !continuations.isEmpty else { return nil }
            return continuations.removeFirst()
        }
        continuation?.resume()
    }
}
