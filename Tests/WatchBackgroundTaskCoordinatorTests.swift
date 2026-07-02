// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import WatchConnectivity
import XCTest

nonisolated final class WatchBackgroundTaskCoordinatorTests: XCTestCase {
    @MainActor
    func testTaskArrivalCompletesOnlyWhenActivatedAndNoContentPending() async {
        let session = MockWatchConnectivitySession()
        let clock = MockObserverClock()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: clock)

        session.activationState = .activated
        session.hasContentPending = false
        let ready = SpyWatchBackgroundRefreshTask()
        coordinator.handle(ready)
        XCTAssertEqual(ready.completeCallCount, 1)

        session.activationState = .notActivated
        session.hasContentPending = false
        let notActivated = SpyWatchBackgroundRefreshTask()
        coordinator.handle(notActivated)
        XCTAssertEqual(notActivated.completeCallCount, 0)

        session.activationState = .activated
        session.hasContentPending = true
        let pending = SpyWatchBackgroundRefreshTask()
        coordinator.handle(pending)
        XCTAssertEqual(pending.completeCallCount, 0)
    }

    @MainActor
    func testSessionEventCompletesHeldTaskWhenContentPendingClears() async {
        let session = MockWatchConnectivitySession()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: MockObserverClock())
        let task = SpyWatchBackgroundRefreshTask()
        session.activationState = .activated
        session.hasContentPending = true

        coordinator.handle(task)
        session.hasContentPending = false
        session.emitSessionEvent()

        XCTAssertEqual(task.completeCallCount, 1)
    }

    @MainActor
    func testSessionEventDoesNotCompleteWhileStillPending() async {
        let session = MockWatchConnectivitySession()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: MockObserverClock())
        let task = SpyWatchBackgroundRefreshTask()
        session.activationState = .activated
        session.hasContentPending = true

        coordinator.handle(task)
        session.emitSessionEvent()

        XCTAssertEqual(task.completeCallCount, 0)
    }

    @MainActor
    func testActivationSessionEventCompletesPreActivationTask() async {
        let session = MockWatchConnectivitySession()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: MockObserverClock())
        let task = SpyWatchBackgroundRefreshTask()
        session.activationState = .notActivated
        session.hasContentPending = false

        coordinator.handle(task)
        session.activationState = .activated
        session.emitSessionEvent()

        XCTAssertEqual(task.completeCallCount, 1)
    }

    @MainActor
    func testDeadlineForceCompletesHeldTaskAndLateEventsDoNotDoubleComplete() async {
        let session = MockWatchConnectivitySession()
        let clock = MockObserverClock()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: clock, deadline: .seconds(12))
        let task = SpyWatchBackgroundRefreshTask()
        session.activationState = .activated
        session.hasContentPending = true

        coordinator.handle(task)
        await self.drain(until: { clock.pendingSleeperCount == 1 })
        clock.advance(by: 12)
        await self.drain(until: { task.completeCallCount == 1 })

        session.hasContentPending = false
        session.emitSessionEvent()

        XCTAssertEqual(task.completeCallCount, 1)
    }

    @MainActor
    func testEarlyDrainCancelsDeadlineSoNextTaskGetsFreshDeadline() async {
        let session = MockWatchConnectivitySession()
        let clock = MockObserverClock()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: clock, deadline: .seconds(12))
        session.activationState = .activated
        session.hasContentPending = true
        let first = SpyWatchBackgroundRefreshTask()

        coordinator.handle(first)
        await self.drain(until: { clock.pendingSleeperCount == 1 })
        session.hasContentPending = false
        session.emitSessionEvent()
        XCTAssertEqual(first.completeCallCount, 1)

        clock.advance(by: 6)
        session.hasContentPending = true
        let second = SpyWatchBackgroundRefreshTask()
        coordinator.handle(second)
        await self.drain(until: { clock.pendingSleeperCount == 2 })

        clock.advance(by: 6)
        await self.drain()
        XCTAssertEqual(second.completeCallCount, 0)

        clock.advance(by: 6)
        await self.drain(until: { second.completeCallCount == 1 })
        XCTAssertEqual(second.completeCallCount, 1)
    }

    @MainActor
    func testCoalescesTwoHeldTasksAndCompletesThirdImmediatelyAfterSessionClears() async {
        let session = MockWatchConnectivitySession()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: MockObserverClock())
        session.activationState = .activated
        session.hasContentPending = true
        let first = SpyWatchBackgroundRefreshTask()
        let second = SpyWatchBackgroundRefreshTask()

        coordinator.handle(first)
        coordinator.handle(second)
        XCTAssertEqual(first.completeCallCount, 0)
        XCTAssertEqual(second.completeCallCount, 0)

        session.hasContentPending = false
        session.emitSessionEvent()
        XCTAssertEqual(first.completeCallCount, 1)
        XCTAssertEqual(second.completeCallCount, 1)

        let third = SpyWatchBackgroundRefreshTask()
        coordinator.handle(third)
        XCTAssertEqual(third.completeCallCount, 1)
    }

    @MainActor
    func testEvaluationReadsSessionStateFreshOnEachEvent() async {
        let session = MockWatchConnectivitySession()
        let coordinator = WatchBackgroundTaskCoordinator(session: session, clock: MockObserverClock())

        session.activationState = .notActivated
        session.hasContentPending = false
        let activationTask = SpyWatchBackgroundRefreshTask()
        coordinator.handle(activationTask)
        session.activationState = .activated
        session.emitSessionEvent()
        XCTAssertEqual(activationTask.completeCallCount, 1)

        session.activationState = .activated
        session.hasContentPending = true
        let contentTask = SpyWatchBackgroundRefreshTask()
        coordinator.handle(contentTask)
        session.hasContentPending = false
        session.emitSessionEvent()
        XCTAssertEqual(contentTask.completeCallCount, 1)
    }

    @MainActor
    func testSessionEventDoesNotClobberReceiveUserInfoHook() async {
        let session = MockWatchConnectivitySession()
        var events: [String] = []
        session.onReceiveUserInfo = { userInfo in
            if userInfo["ok"] as? Bool == true {
                events.append("userInfo")
            }
        }
        session.onSessionEvent = {
            events.append("session")
        }

        session.deliverUserInfo(["ok": true])

        XCTAssertEqual(events, ["userInfo", "session"])
    }

    @MainActor
    private func drain(until condition: () -> Bool = { true }, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
        await Task.yield()
    }
}

@MainActor
private final class SpyWatchBackgroundRefreshTask: WatchBackgroundRefreshTask {
    var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    private(set) var completeCallCount = 0

    func complete() {
        self.completeCallCount += 1
    }
}
