// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Observation
import XCTest

/// The runner around `ConnectionPresenter`: it reacts to input changes without waiting for a
/// tick, and wakes for the presenter's own deadlines. The timing rules themselves are in
/// `ConnectionPresenterTests`.
@MainActor
final class ConnectionSyncModelTests: XCTestCase {
    func testAHardDropPublishesOnTheInputChangeWithoutAClockAdvance() async {
        let clock = MockObserverClock()
        let box = ObservableInputBox(Self.connected(heard: clock.now()))
        let model = ConnectionSyncModel(clock: clock) { box.inputs }
        XCTAssertEqual(model.status, .connectedIdle)
        let task = Task { await model.run() }
        await Self.drainUntilPendingSleeperCount(1, in: clock)

        clock.advance(by: 1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        box.inputs = Self.inputs(tunnelState: .error(.muxTeardown), reconnectCountdown: 1)
        await Self.drain { model.status == .reconnecting }

        XCTAssertEqual(model.status, .reconnecting)
        await Self.cancel(task, advancing: clock)
    }

    func testTheTimerWithdrawsConnectedWhenTheLeaseRunsOut() async {
        let clock = MockObserverClock()
        let heard = clock.now()
        let model = ConnectionSyncModel(clock: clock) { Self.connected(heard: heard) }
        XCTAssertEqual(model.status, .connectedIdle)
        let task = Task { await model.run() }

        for _ in 0..<11 {
            await Self.drainUntilPendingSleeperCount(1, in: clock)
            clock.advance(by: 1)
        }
        await Self.drain { model.status != .connectedIdle }

        XCTAssertEqual(model.status, .unreachable)
        await Self.cancel(task, advancing: clock)
    }

    func testForegroundHoldsTheLastStateWhileAFreshProbeAnswers() {
        let clock = MockObserverClock()
        let box = InputBox(Self.connected(heard: clock.now()))
        let model = ConnectionSyncModel(clock: clock) { box.inputs }
        XCTAssertEqual(model.status, .connectedIdle)

        clock.advance(by: 60)
        model.noteForeground()
        XCTAssertEqual(model.status, .connectedIdle)

        box.inputs = Self.connected(heard: clock.now())
        model.noteForeground()
        XCTAssertEqual(model.status, .connectedIdle)
    }

    func testRefreshNowShowsASeededStateWithoutHolding() {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(tunnelState: .disconnected))
        let model = ConnectionSyncModel(clock: clock) { box.inputs }
        XCTAssertEqual(model.status, .connecting)

        model.refreshNow()
        XCTAssertEqual(model.status, .offline)

        box.inputs = Self.connected(heard: clock.now())
        model.refreshNow()
        XCTAssertEqual(model.status, .connectedIdle)
    }

    func testSyncingLingerIsPublishedForThePill() async {
        let clock = MockObserverClock()
        let box = ObservableInputBox(Self.connected(heard: clock.now(), captureBacklog: 1))
        let model = ConnectionSyncModel(clock: clock) { box.inputs }
        let task = Task { await model.run() }
        await Self.drainUntilPendingSleeperCount(1, in: clock)

        box.inputs = Self.connected(heard: clock.now(), captureBacklog: 0)
        await Self.drain { model.syncingLingers }
        XCTAssertTrue(model.syncingLingers)

        await Self.drainUntilPendingSleeperCount(1, in: clock)
        clock.advance(by: 1.5)
        await Self.drain { !model.syncingLingers }
        XCTAssertFalse(model.syncingLingers)

        await Self.cancel(task, advancing: clock)
    }

    // MARK: - helpers

    private static func drainUntilPendingSleeperCount(_ count: Int, in clock: MockObserverClock) async {
        for _ in 0..<200 where clock.pendingSleeperCount < count {
            await Task.yield()
        }
    }

    private static func drain(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    private static func cancel(_ task: Task<Void, Never>, advancing clock: MockObserverClock) async {
        task.cancel()
        clock.advance(by: 10)
        await task.value
    }

    private final class InputBox {
        var inputs: ConnectionSyncInputs

        init(_ inputs: ConnectionSyncInputs) {
            self.inputs = inputs
        }
    }

    @Observable
    final class ObservableInputBox {
        var inputs: ConnectionSyncInputs

        init(_ inputs: ConnectionSyncInputs) {
            self.inputs = inputs
        }
    }

    private static func connected(heard: Date, captureBacklog: Int = 0) -> ConnectionSyncInputs {
        self.inputs(
            tunnelState: .connected(localPort: 42, via: .lan),
            backlogPending: captureBacklog,
            lastHeardAt: heard,
            captureBacklog: captureBacklog
        )
    }

    private static func inputs(
        tunnelState: TunnelState,
        reconnectCountdown: Int? = nil,
        isNetworkSatisfied: Bool? = true,
        backlogPending: Int = 0,
        lastHeardAt: Date? = nil,
        captureBacklog: Int = 0
    ) -> ConnectionSyncInputs {
        ConnectionSyncInputs(
            tunnelState: tunnelState,
            reconnectCountdown: reconnectCountdown,
            isNetworkSatisfied: isNetworkSatisfied,
            confirmedTransferCount: 0,
            recentBytesPerSecond: 0,
            backlogPending: backlogPending,
            backlogFailed: 0,
            lastHeardAt: lastHeardAt,
            captureBacklog: captureBacklog
        )
    }
}
