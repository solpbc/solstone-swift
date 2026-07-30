// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Observation
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

    func testLeavingReachablePublishesOnNextDerivation() async {
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

        XCTAssertEqual(model.status, .offline)
        XCTAssertFalse(isJournalReachable(model.status))

        await Self.cancel(task, advancing: clock)
    }

    func testPinnedBackoffOutageLeavesReachableOnFirstDerivation() async {
        let clock = MockObserverClock()
        let outageStart = clock.now().addingTimeInterval(0.1)
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: {
                Self.pinnedBackoffCycleInputs(clock: clock, outageStart: outageStart)
            }
        )
        let task = Task { await model.run() }

        XCTAssertEqual(model.status, .connectedIdle)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        clock.advance(by: 0.1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)

        XCTAssertEqual(model.status, .reconnecting)
        XCTAssertFalse(isJournalReachable(model.status))

        await Self.cancel(task, advancing: clock)
    }

    func testOscillatingNonReachableOutageCannotDeferReachableLeave() async {
        let clock = MockObserverClock()
        let outageStart = clock.now().addingTimeInterval(0.1)
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: {
                Self.oscillatingOutageInputs(clock: clock, outageStart: outageStart)
            }
        )
        let task = Task { await model.run() }

        XCTAssertEqual(model.status, .connectedIdle)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        clock.advance(by: 0.1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertFalse(isJournalReachable(model.status))

        clock.advance(by: 1.5)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertFalse(isJournalReachable(model.status))

        await Self.cancel(task, advancing: clock)
    }

    func testSubDebounceFlapDoesNotPublish() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .offline))
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: { box.inputs }
        )
        let task = Task { await model.run() }

        await Self.drainUntilPendingSleeperCount(1, in: clock)
        box.inputs = Self.inputs(status: .connectedIdle)
        clock.advance(by: 0.1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)

        clock.advance(by: 1.4)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .offline)

        box.inputs = Self.inputs(status: .offline)
        clock.advance(by: 0.2)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .offline)

        await Self.cancel(task, advancing: clock)
    }

    func testStableDebouncedTransitionPublishes() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .offline))
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
        XCTAssertEqual(model.status, .offline)
        XCTAssertFalse(isJournalReachable(model.status))

        clock.advance(by: 1.5)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedTransferring)
        XCTAssertTrue(isJournalReachable(model.status))

        await Self.cancel(task, advancing: clock)
    }

    func testCandidateRevertingBeforeDebounceIsCancelled() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .offline))
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
        XCTAssertEqual(model.status, .offline)

        box.inputs = Self.inputs(status: .offline)
        clock.advance(by: 1.5)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .offline)

        await Self.cancel(task, advancing: clock)
    }

    func testInputObservationPublishesLeavingReachableWithoutClockAdvance() async {
        let clock = MockObserverClock()
        let manager = TunnelManager(transport: MockCFTunnelTransport())
        manager.state = .connected(localPort: 42, via: .lan)
        manager.isNetworkSatisfied = true
        var sampleReadCount = 0
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: {
                sampleReadCount += 1
                return ConnectionSyncInputs(
                    tunnelState: manager.state,
                    reconnectCountdown: manager.reconnectCountdown,
                    isNetworkSatisfied: manager.isNetworkSatisfied,
                    confirmedTransferCount: 0,
                    recentBytesPerSecond: 0,
                    backlogPending: 0,
                    backlogFailed: 0
                )
            }
        )
        let task = Task { await model.run() }

        await Self.drainUntil {
            clock.pendingSleeperCount == 1 && sampleReadCount >= 2
        }

        manager.reconnectCountdown = 1
        manager.state = .error(.muxTeardown)

        await Self.drainUntil {
            !isJournalReachable(model.status)
        }
        XCTAssertEqual(model.status, .reconnecting)

        await Self.cancel(task, advancing: clock)
    }

    func testRefreshFromInputChangePublishesImmediateLeaveWithoutPoll() {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .connectedIdle))
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: { box.inputs }
        )

        box.inputs = Self.inputs(status: .offline)
        model.refreshFromInputChange()

        XCTAssertEqual(model.status, .offline)
    }

    func testNetworkBlipWhileTunnelConnectedDoesNotPublishFromInputObservation() async {
        let clock = MockObserverClock()
        let box = ObservableInputBox(Self.inputs(status: .connectedIdle))
        var sampleReadCount = 0
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: {
                sampleReadCount += 1
                return box.inputs
            }
        )
        let task = Task { await model.run() }

        await Self.drainUntil {
            clock.pendingSleeperCount == 1 && sampleReadCount >= 2
        }
        let readsBeforeBlip = sampleReadCount

        box.inputs = Self.inputs(
            tunnelState: .connected(localPort: 42, via: .lan),
            isNetworkSatisfied: false
        )

        await Self.drainUntil {
            sampleReadCount > readsBeforeBlip
        }
        XCTAssertEqual(model.status, .connectedIdle)
        XCTAssertTrue(isJournalReachable(model.status))

        await Self.cancel(task, advancing: clock)
    }

    func testNetworkBlipResolvingWithinPollCadenceDoesNotSurviveConfirm() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .connectedIdle))
        let model = ConnectionSyncModel(
            clock: clock,
            sample: { box.inputs }
        )
        let task = Task { await model.run() }

        await Self.drainUntilPendingSleeperCount(1, in: clock)
        box.inputs = Self.inputs(
            tunnelState: .connected(localPort: 42, via: .lan),
            isNetworkSatisfied: false
        )
        clock.advance(by: 1.0)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedIdle)

        box.inputs = Self.inputs(status: .connectedIdle)
        clock.advance(by: 1.0)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedIdle)

        clock.advance(by: 0.5)
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        XCTAssertEqual(model.status, .connectedIdle)

        await Self.cancel(task, advancing: clock)
    }

    func testWithinReachableTransitionPublishesWithoutConfirm() async {
        let clock = MockObserverClock()
        let box = InputBox(Self.inputs(status: .connectedIdle))
        let model = ConnectionSyncModel(
            clock: clock,
            debounceInterval: .milliseconds(1_500),
            pollCadence: .milliseconds(100),
            sample: { box.inputs }
        )
        let task = Task { await model.run() }

        XCTAssertTrue(isJournalReachable(model.status))
        await Self.drainUntilPendingSleeperCount(1, in: clock)
        box.inputs = Self.inputs(status: .connectedTransferring)
        clock.advance(by: 0.1)
        await Self.drainUntilPendingSleeperCount(1, in: clock)

        XCTAssertEqual(model.status, .connectedTransferring)
        XCTAssertTrue(isJournalReachable(model.status))

        await Self.cancel(task, advancing: clock)
    }

    private static func drainUntilPendingSleeperCount(
        _ expectedCount: Int,
        in clock: MockObserverClock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while clock.pendingSleeperCount != expectedCount, yields < 10_000 {
            await Task.yield()
            yields += 1
        }
        XCTAssertEqual(clock.pendingSleeperCount, expectedCount, file: file, line: line)
    }

    private static func drainUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while !condition(), yields < 10_000 {
            await Task.yield()
            yields += 1
        }
        XCTAssertTrue(condition(), file: file, line: line)
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

    private static func pinnedBackoffCycleInputs(
        clock: MockObserverClock,
        outageStart: Date
    ) -> ConnectionSyncInputs {
        let now = clock.now()
        guard now >= outageStart else {
            return self.inputs(status: .connectedIdle)
        }

        let elapsed = now.timeIntervalSince(outageStart)
        switch elapsed {
        case ..<0.750:
            return self.inputs(tunnelState: .error(.muxTeardown), reconnectCountdown: 1)
        case ..<0.850:
            return self.inputs(status: .connecting)
        case ..<4.600:
            return self.inputs(tunnelState: .error(.muxTeardown), reconnectCountdown: 4)
        case ..<4.700:
            return self.inputs(status: .connecting)
        case ..<12.200:
            return self.inputs(tunnelState: .error(.muxTeardown), reconnectCountdown: 8)
        case ..<12.300:
            return self.inputs(status: .connecting)
        default:
            return self.inputs(tunnelState: .error(.muxTeardown), reconnectCountdown: 23)
        }
    }

    private static func oscillatingOutageInputs(
        clock: MockObserverClock,
        outageStart: Date
    ) -> ConnectionSyncInputs {
        let now = clock.now()
        guard now >= outageStart else {
            return self.inputs(status: .connectedIdle)
        }

        let elapsed = max(now.timeIntervalSince(outageStart), 0)
        switch Int(elapsed.rounded(.down)) % 4 {
        case 0:
            return self.inputs(status: .reconnecting)
        case 1:
            return self.inputs(status: .connecting)
        case 2:
            return self.inputs(status: .unreachable)
        default:
            return self.inputs(status: .waitingForHome)
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
