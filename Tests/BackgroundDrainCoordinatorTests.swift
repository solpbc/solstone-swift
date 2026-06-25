// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class BackgroundDrainCoordinatorTests: XCTestCase {
    @MainActor
    func testDrainedTerminalRunsDriveOnceAndDisconnects() async {
        let totals = TotalsBox(failed: 1, pending: 1)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                totals.failed = 0
                totals.pending = 0
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testNoForwardProgressStopsAfterOneDriveAndDisconnects() async {
        let totals = TotalsBox(failed: 0, pending: 2)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testMultiCycleProgressThenDrainedUsesClockSettle() async {
        let totals = TotalsBox(failed: 4, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let clock = MockObserverClock()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                if counters.driveCount == 1 {
                    totals.failed = 3
                } else {
                    totals.failed = 0
                }
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.run()
        }
        await self.drain(until: {
            counters.driveCount == 1 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(self.pendingSleeperCount(in: clock), 1)

        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 2)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testExpirationTerminalDisconnectsAndEndsOnce() async {
        let totals = TotalsBox(failed: 1, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                asserter.fireExpiration()
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testSustainDoesNotBeginDriveOrDisconnect() async {
        let totals = TotalsBox(failed: 1, pending: 1)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { true },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 0)
        XCTAssertEqual(asserter.beginCount, 0)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testEmptyBacklogDisconnectsWithoutBeginningOrDriving() async {
        let totals = TotalsBox(failed: 0, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 0)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testNotConnectedBacklogDisconnectsWithoutBeginning() async {
        let totals = TotalsBox(failed: 2, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { false },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 0)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testInvalidBackgroundAssertionDisconnectsWithoutDriving() async {
        let totals = TotalsBox(failed: 1, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        asserter.beginReturn = false
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testEndIsIdempotentWhenExpirationAndCompletionBothRun() async {
        let totals = TotalsBox(failed: 1, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                asserter.fireExpiration()
                totals.failed = 0
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    private func drain(until condition: () -> Bool, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
    }

    @MainActor
    private func pendingSleeperCount(in clock: MockObserverClock) -> Int {
        guard let sleepers = Mirror(reflecting: clock).children.first(where: { $0.label == "sleepers" }) else {
            return 0
        }
        return Mirror(reflecting: sleepers.value).children.count
    }
}

@MainActor
private final class TotalsBox {
    var failed: Int
    var pending: Int

    init(failed: Int, pending: Int) {
        self.failed = failed
        self.pending = pending
    }

    var snapshot: (failed: Int, pending: Int) {
        (failed: self.failed, pending: self.pending)
    }
}

@MainActor
private final class CountersBox {
    var driveCount = 0
    var disconnectCount = 0
}

@MainActor
private final class SpyBackgroundTaskAsserter: BackgroundTaskAsserting {
    var beginReturn = true
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var handler: (@MainActor () -> Void)?

    func begin(expirationHandler: @escaping @MainActor () -> Void) -> Bool {
        self.beginCount += 1
        self.handler = expirationHandler
        return self.beginReturn
    }

    func end() {
        self.endCount += 1
    }

    func fireExpiration() {
        self.handler?()
    }
}
