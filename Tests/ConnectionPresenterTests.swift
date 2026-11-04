// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

/// Scripted traces through the presenter. Each test is one owner-visible promise:
/// connected is earned, a drop shows at once, nothing flashes, opening the app doesn't blink.
nonisolated final class ConnectionPresenterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - connected is earned

    func testConnectedIsNeverShownWithoutBeingHeardWithinTheLease() {
        var presenter = self.launched()
        presenter.step(Self.connected(heard: nil), now: self.at(1))
        XCTAssertFalse(isJournalReachable(presenter.shown))

        presenter.step(Self.connected(heard: self.at(-11)), now: self.at(1))
        XCTAssertFalse(isJournalReachable(presenter.shown))

        presenter.step(Self.connected(heard: self.at(1)), now: self.at(1))
        XCTAssertEqual(presenter.shown, .connectedIdle)
    }

    func testAFreshLaunchShowsConnectingUntilEarnedAndNeverFlashesOffline() {
        var presenter = self.launched()
        XCTAssertEqual(presenter.shown, .connecting)

        // The tunnel hasn't started yet: no offline flash inside the launch grace.
        presenter.step(Self.inputs(.disconnected), now: self.at(0.2))
        XCTAssertEqual(presenter.shown, .connecting)

        presenter.step(Self.connected(heard: self.at(0.3)), now: self.at(0.3))
        XCTAssertEqual(presenter.shown, .connectedIdle)
    }

    func testRecoveryShowsOnFirstEvidenceWithNoConfirmTimer() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.inputs(.error(.muxTeardown), reconnectCountdown: 1), now: self.at(5))
        XCTAssertEqual(presenter.shown, .reconnecting)

        presenter.step(Self.connected(heard: self.at(8)), now: self.at(8))
        XCTAssertEqual(presenter.shown, .connectedIdle)
    }

    // MARK: - drops

    func testAHardDropShowsWithinOneEvaluation() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.inputs(.error(.muxTeardown), reconnectCountdown: 1), now: self.at(5))
        XCTAssertFalse(isJournalReachable(presenter.shown))
    }

    func testOneSlowProbeInsideTheLeaseChangesNothing() {
        var presenter = self.connectedPresenter(heardAt: 0)
        // The next answer arrives 9 s later: one full 3 s interval plus a 6 s probe.
        for second in stride(from: 1.0, through: 9.0, by: 1.0) {
            presenter.step(Self.connected(heard: self.at(0)), now: self.at(second))
            XCTAssertEqual(presenter.shown, .connectedIdle, "at \(second)s")
        }
        presenter.step(Self.connected(heard: self.at(9)), now: self.at(9))
        XCTAssertEqual(presenter.shown, .connectedIdle)
    }

    func testASilentLossShowsWhenTheLeaseRunsOut() {
        var presenter = self.connectedPresenter(heardAt: 0)
        presenter.step(Self.connected(heard: self.at(0)), now: self.at(10))
        XCTAssertEqual(presenter.shown, .connectedIdle)
        presenter.step(Self.connected(heard: self.at(0)), now: self.at(10.5))
        XCTAssertEqual(presenter.shown, .unreachable)
    }

    func testADropIsShownAtLeastOneSecondBeforeConnectedReturns() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.inputs(.error(.muxTeardown), reconnectCountdown: 1), now: self.at(5))
        XCTAssertEqual(presenter.shown, .reconnecting)

        presenter.step(Self.connected(heard: self.at(5.3)), now: self.at(5.3))
        XCTAssertEqual(presenter.shown, .reconnecting)
        XCTAssertEqual(presenter.nextDeadline(after: self.at(5.3)), self.at(6))

        presenter.step(Self.connected(heard: self.at(5.3)), now: self.at(6))
        XCTAssertEqual(presenter.shown, .connectedIdle)
    }

    // MARK: - offline

    func testThirtySecondsOfNotReachingReadsOffline() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.inputs(.error(.unreachable)), now: self.at(5))
        XCTAssertEqual(presenter.shown, .unreachable)

        presenter.step(Self.inputs(.connecting), now: self.at(20))
        XCTAssertEqual(presenter.shown, .connecting)

        presenter.step(Self.inputs(.error(.unreachable)), now: self.at(35))
        XCTAssertEqual(presenter.shown, .offline)
    }

    func testNoNetworkWithTheTunnelDownIsOfflineAtOnce() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.inputs(.error(.muxTeardown), isNetworkSatisfied: false), now: self.at(5))
        XCTAssertEqual(presenter.shown, .offline)
    }

    func testAPathReadingAloneNeverSaysOfflineWhileTheJournalIsHeard() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.connected(heard: self.at(4), isNetworkSatisfied: false), now: self.at(5))
        XCTAssertEqual(presenter.shown, .connectedIdle)
    }

    func testTheNetworkReturningStartsANewAttempt() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.inputs(.error(.unreachable)), now: self.at(5))
        presenter.step(Self.inputs(.error(.unreachable)), now: self.at(40))
        XCTAssertEqual(presenter.shown, .offline)

        presenter.step(Self.inputs(.error(.unreachable), isNetworkSatisfied: false), now: self.at(41))
        presenter.step(Self.inputs(.connecting, isNetworkSatisfied: true), now: self.at(42))
        XCTAssertEqual(presenter.shown, .connecting)
    }

    // MARK: - foreground

    func testReturningToTheForegroundDoesNotBlinkWhenTheProbeAnswersQuickly() {
        var presenter = self.connectedPresenter(heardAt: 0)
        // Suspended for a minute: the last answer is long past the lease.
        presenter.noteForeground(now: self.at(60))
        presenter.step(Self.connected(heard: self.at(0)), now: self.at(60))
        XCTAssertEqual(presenter.shown, .connectedIdle)

        presenter.step(Self.connected(heard: self.at(60.3)), now: self.at(60.3))
        XCTAssertEqual(presenter.shown, .connectedIdle)
    }

    func testReturningToTheForegroundShowsTheTruthAfterTheGrace() {
        var presenter = self.connectedPresenter(heardAt: 0)
        presenter.noteForeground(now: self.at(60))
        presenter.step(Self.connected(heard: self.at(0)), now: self.at(60.2))
        XCTAssertEqual(presenter.shown, .connectedIdle)
        XCTAssertEqual(presenter.nextDeadline(after: self.at(60.2)), self.at(60.5))

        presenter.step(Self.connected(heard: self.at(0)), now: self.at(60.5))
        XCTAssertEqual(presenter.shown, .unreachable)
    }

    func testReturningToTheForegroundAfterGoingOfflineStartsANewAttempt() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.inputs(.error(.unreachable)), now: self.at(5))
        presenter.step(Self.inputs(.error(.unreachable)), now: self.at(40))
        XCTAssertEqual(presenter.shown, .offline)

        presenter.noteForeground(now: self.at(100))
        presenter.step(Self.inputs(.connecting), now: self.at(100.5))
        XCTAssertEqual(presenter.shown, .connecting)
    }

    // MARK: - syncing

    func testSyncingLingersAfterTheQueueDrains() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.connected(heard: self.at(5), captureBacklog: 1), now: self.at(5))
        XCTAssertFalse(presenter.syncingLingers)

        presenter.step(Self.connected(heard: self.at(6), captureBacklog: 0), now: self.at(6))
        XCTAssertTrue(presenter.syncingLingers)
        presenter.step(Self.connected(heard: self.at(7), captureBacklog: 0), now: self.at(7.4))
        XCTAssertTrue(presenter.syncingLingers)
        XCTAssertEqual(presenter.nextDeadline(after: self.at(7.4)), self.at(7.5))

        presenter.step(Self.connected(heard: self.at(7), captureBacklog: 0), now: self.at(7.5))
        XCTAssertFalse(presenter.syncingLingers)
    }

    func testANewItemDuringTheLingerKeepsSyncingContinuous() {
        var presenter = self.connectedPresenter()
        presenter.step(Self.connected(heard: self.at(5), captureBacklog: 1), now: self.at(5))
        presenter.step(Self.connected(heard: self.at(6), captureBacklog: 0), now: self.at(6))
        presenter.step(Self.connected(heard: self.at(6.5), captureBacklog: 1), now: self.at(6.5))
        XCTAssertFalse(presenter.syncingLingers)
        presenter.step(Self.connected(heard: self.at(7), captureBacklog: 0), now: self.at(7))
        XCTAssertTrue(presenter.syncingLingers)
    }

    // MARK: - helpers

    private func at(_ seconds: TimeInterval) -> Date {
        self.t0.addingTimeInterval(seconds)
    }

    private func launched() -> ConnectionPresenter {
        ConnectionPresenter(now: self.t0)
    }

    private func connectedPresenter(heardAt: TimeInterval = 0) -> ConnectionPresenter {
        var presenter = self.launched()
        presenter.step(Self.connected(heard: self.at(heardAt)), now: self.at(heardAt))
        XCTAssertEqual(presenter.shown, .connectedIdle)
        return presenter
    }

    private static func connected(
        heard: Date?,
        isNetworkSatisfied: Bool? = true,
        captureBacklog: Int = 0
    ) -> ConnectionSyncInputs {
        self.inputs(
            .connected(localPort: 42, via: .lan),
            isNetworkSatisfied: isNetworkSatisfied,
            backlogPending: captureBacklog,
            lastHeardAt: heard,
            captureBacklog: captureBacklog
        )
    }

    private static func inputs(
        _ tunnelState: TunnelState,
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
