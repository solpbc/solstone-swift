// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class OmiReconciliationSchedulerTests: XCTestCase {
    private actor Barrier {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func suspend() async {
            self.isWaiting = true
            await withCheckedContinuation { self.continuation = $0 }
        }

        func resume() {
            self.isWaiting = false
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    @MainActor
    private final class PassLog {
        var count = 0
        var onPass: (@MainActor (Int) async -> Void)?

        func record() async {
            self.count += 1
            await self.onPass?(self.count)
        }
    }

    @MainActor
    private func makeScheduler(clock: MockObserverClock = MockObserverClock()) -> (OmiReconciliationScheduler, PassLog, MockObserverClock) {
        let log = PassLog()
        let scheduler = OmiReconciliationScheduler(clock: clock, pace: .seconds(1)) { await log.record() }
        return (scheduler, log, clock)
    }

    /// Lets any dispatched follow-up task run and register its sleeper on the mock clock.
    @MainActor
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    @MainActor func testRequestsDuringOnePassCoalesceIntoOneImmediateFollowUp() async throws {
        let (scheduler, log, clock) = self.makeScheduler()
        let barrier = Barrier()
        log.onPass = { count in
            if count == 1 { await barrier.suspend() }
        }
        let first = Task { @MainActor in await scheduler.run() }
        try await transferTestWaitFor("first pass suspended") { await barrier.isWaiting }

        await scheduler.run()
        scheduler.request(.immediate)
        scheduler.request(.immediate)
        await scheduler.run()
        XCTAssertEqual(log.count, 1, "overlapping requests cannot start a second pass")

        await barrier.resume()
        await first.value
        await self.settle()
        XCTAssertEqual(log.count, 2, "exactly one follow-up pass runs")
        XCTAssertEqual(clock.pendingSleeperCount, 0, "an immediate follow-up does not sleep")
    }

    @MainActor func testFirstUrgencyRequestedDuringAPassWins() async throws {
        // paced first, immediate second → the paced wait wins.
        let pacedFirst = self.makeScheduler()
        pacedFirst.1.onPass = { count in
            if count == 1 {
                pacedFirst.0.request(.paced)
                pacedFirst.0.request(.immediate)
            }
        }
        await pacedFirst.0.run()
        await self.settle()
        XCTAssertEqual(pacedFirst.1.count, 1, "the paced follow-up does not run before the clock fires")
        XCTAssertEqual(pacedFirst.2.pendingSleeperCount, 1)

        // immediate first, paced second → runs at once.
        let immediateFirst = self.makeScheduler()
        immediateFirst.1.onPass = { count in
            if count == 1 {
                immediateFirst.0.request(.immediate)
                immediateFirst.0.request(.paced)
            }
        }
        await immediateFirst.0.run()
        await self.settle()
        XCTAssertEqual(immediateFirst.1.count, 2)
        XCTAssertEqual(immediateFirst.2.pendingSleeperCount, 0)
    }

    @MainActor func testPacedRequestDuringPassArmsExactlyOneSleeper() async throws {
        let (scheduler, log, clock) = self.makeScheduler()
        log.onPass = { count in
            if count == 1 {
                scheduler.request(.paced)
                scheduler.request(.paced)
            }
        }
        await scheduler.run()
        await self.settle()
        XCTAssertEqual(log.count, 1, "a paced follow-up does not run before the clock fires")
        XCTAssertEqual(clock.pendingSleeperCount, 1)

        clock.advance(by: 1)
        try await transferTestWaitFor("paced follow-up") { await MainActor.run { log.count == 2 } }
        await self.settle()
        XCTAssertEqual(clock.pendingSleeperCount, 0, "a pass that owes nothing leaves the scheduler idle")
    }

    @MainActor func testPacedRequestWhileIdleArmsExactlyOneSleeper() async throws {
        let (scheduler, log, clock) = self.makeScheduler()
        scheduler.request(.paced)
        scheduler.request(.paced)
        await self.settle()
        XCTAssertEqual(clock.pendingSleeperCount, 1)
        XCTAssertEqual(log.count, 0)

        clock.advance(by: 1)
        try await transferTestWaitFor("sleeper wakes into one pass") { await MainActor.run { log.count == 1 } }
        await self.settle()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(clock.pendingSleeperCount, 0)
    }

    @MainActor func testImmediateRequestWhileSleeperIsArmedSupersedesTheWait() async throws {
        let (scheduler, log, clock) = self.makeScheduler()
        scheduler.request(.paced)
        await self.settle()
        XCTAssertEqual(clock.pendingSleeperCount, 1)

        scheduler.request(.immediate)
        try await transferTestWaitFor("immediate pass runs without waiting for the clock") {
            await MainActor.run { log.count == 1 }
        }

        // The superseded paced wait is cancelled: firing its clock must not run a second pass.
        clock.advance(by: 1)
        await self.settle()
        XCTAssertEqual(log.count, 1, "the cancelled paced wait does not fire a second pass")
    }

    @MainActor func testRunFromInsideThePassOwesOneFollowUpWithoutRecursing() async throws {
        let (scheduler, log, clock) = self.makeScheduler()
        log.onPass = { count in
            if count == 1 {
                await scheduler.run()
                await scheduler.run()
            }
        }
        await scheduler.run()
        await self.settle()
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(clock.pendingSleeperCount, 0)
    }

    @MainActor func testPassOwingNothingLeavesSchedulerIdle() async throws {
        let (scheduler, log, clock) = self.makeScheduler()
        await scheduler.run()
        await self.settle()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(clock.pendingSleeperCount, 0)
    }
}
