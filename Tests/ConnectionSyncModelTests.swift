// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

@MainActor
final class ConnectionSyncModelTests: XCTestCase {
    func testRefreshNowPublishesCurrentSampleWithoutDebounce() {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .offline))
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: { box.inputs }
        )

        box.inputs = Self.inputs(status: .connectedIdle)
        model.refreshNow()

        XCTAssertEqual(model.status, .connectedIdle)
    }

    func testSubDebounceFlapDoesNotPublish() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .connectedIdle))
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: { box.inputs }
        )
        let task = Task { await model.run() }

        await Self.drainUntilPendingSleeperCount(1, in: clock)
        box.inputs = Self.inputs(status: .offline)
        clock.advance(by: 0.1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)

        clock.advance(by: 1.4)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedIdle)

        box.inputs = Self.inputs(status: .connectedIdle)
        clock.advance(by: 0.2)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedIdle)

        task.cancel()
        clock.advance(by: 10)
        await task.value
    }

    func testStableDebouncedTransitionPublishes() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .connectedIdle))
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: { box.inputs }
        )
        let task = Task { await model.run() }

        await Self.drainUntilPendingSleeperCount(1, in: clock)
        box.inputs = Self.inputs(status: .connectedTransferring)
        clock.advance(by: 0.1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedIdle)

        clock.advance(by: 1.5)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedTransferring)

        task.cancel()
        clock.advance(by: 10)
        await task.value
    }

    func testCandidateRevertingBeforeDebounceIsCancelled() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .connectedIdle))
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: { box.inputs }
        )
        let task = Task { await model.run() }

        await Self.drainUntilPendingSleeperCount(1, in: clock)
        box.inputs = Self.inputs(status: .connectedWaiting)
        clock.advance(by: 0.1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)

        box.inputs = Self.inputs(status: .connectedIdle)
        clock.advance(by: 1.5)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedIdle)

        task.cancel()
        clock.advance(by: 10)
        await task.value
    }

    private static func drainUntilPendingSleeperCount(
        _ expectedCount: Int,
        in clock: MockObserverClock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while Self.pendingSleeperCount(in: clock) != expectedCount, yields < 10_000 {
            await Task.yield()
            yields += 1
        }
        XCTAssertEqual(Self.pendingSleeperCount(in: clock), expectedCount, file: file, line: line)
    }

    private static func pendingSleeperCount(in clock: MockObserverClock) -> Int {
        guard let sleepers = Mirror(reflecting: clock).children.first(where: { $0.label == "sleepers" }) else {
            return 0
        }
        return Mirror(reflecting: sleepers.value).children.count
    }

    private final class InputBox {
        var inputs: ConnectionSyncInputs

        init(_ inputs: ConnectionSyncInputs) {
            self.inputs = inputs
        }
    }

    private static func inputs(status: ConnectionSyncStatus) -> ConnectionSyncInputs {
        switch status {
        case .offline:
            return self.inputs(tunnelState: .disconnected)
        case .connecting:
            return self.inputs(tunnelState: .connecting)
        case .waitingForHome:
            return self.inputs(tunnelState: .waitingForHome)
        case .reconnecting:
            return self.inputs(tunnelState: .error(.muxTeardown), reconnectCountdown: 1)
        case .unreachable:
            return self.inputs(tunnelState: .error(.unreachable))
        case .connectedIdle:
            return self.inputs(tunnelState: .connected(localPort: 42, via: .lan))
        case .connectedWaiting:
            return self.inputs(tunnelState: .connected(localPort: 42, via: .lan), backlogPending: 1)
        case .connectedTransferring:
            return self.inputs(
                tunnelState: .connected(localPort: 42, via: .lan),
                confirmedTransferCount: 1,
                backlogPending: 1
            )
        }
    }

    private static func inputs(
        tunnelState: TunnelState,
        reconnectCountdown: Int? = nil,
        isNetworkSatisfied: Bool? = true,
        confirmedTransferCount: Int = 0,
        recentBytesPerSecond: Double = 0,
        backlogPending: Int = 0,
        backlogFailed: Int = 0
    ) -> ConnectionSyncInputs {
        ConnectionSyncInputs(
            tunnelState: tunnelState,
            reconnectCountdown: reconnectCountdown,
            isNetworkSatisfied: isNetworkSatisfied,
            confirmedTransferCount: confirmedTransferCount,
            recentBytesPerSecond: recentBytesPerSecond,
            backlogPending: backlogPending,
            backlogFailed: backlogFailed
        )
    }
}
