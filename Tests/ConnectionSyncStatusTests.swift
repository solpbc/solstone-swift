// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ConnectionSyncStatusTests: XCTestCase {
    func testStatusLinesAreFunctionalDefaults() {
        XCTAssertEqual(ConnectionSyncStatus.offline.statusLine, "offline")
        XCTAssertEqual(ConnectionSyncStatus.connecting.statusLine, "connecting…")
        XCTAssertEqual(ConnectionSyncStatus.waitingForHome.statusLine, "waiting for your home…")
        XCTAssertEqual(ConnectionSyncStatus.reconnecting.statusLine, "reconnecting…")
        XCTAssertEqual(ConnectionSyncStatus.unreachable.statusLine, "can't reach your journal")
        XCTAssertEqual(ConnectionSyncStatus.connectedIdle.statusLine, "connected")
        XCTAssertEqual(ConnectionSyncStatus.connectedWaiting.statusLine, "connected · waiting to sync")
        XCTAssertEqual(ConnectionSyncStatus.connectedTransferring.statusLine, "connected · syncing")
    }

    func testOfflineDerivesFromDisconnectedOrUnsatisfiedNetwork() {
        XCTAssertEqual(Self.derive(tunnelState: .disconnected), .offline)
        XCTAssertEqual(Self.derive(tunnelState: .connected(localPort: 42, via: .lan), isNetworkSatisfied: false), .offline)
    }

    func testNilNetworkDoesNotForceOffline() {
        XCTAssertEqual(
            Self.derive(tunnelState: .connected(localPort: 42, via: .lan), isNetworkSatisfied: nil),
            .connectedIdle
        )
    }

    func testConnectingAndWaitingForHomeDeriveDirectly() {
        XCTAssertEqual(Self.derive(tunnelState: .connecting), .connecting)
        XCTAssertEqual(Self.derive(tunnelState: .waitingForHome), .waitingForHome)
    }

    func testRetryableErrorWithCountdownIsReconnecting() {
        XCTAssertEqual(
            Self.derive(tunnelState: .error(.muxTeardown), reconnectCountdown: 3),
            .reconnecting
        )
    }

    func testErrorsWithoutActiveCountdownAreUnreachable() {
        XCTAssertEqual(Self.derive(tunnelState: .error(.muxTeardown)), .unreachable)
        XCTAssertEqual(Self.derive(tunnelState: .error(.revoked)), .unreachable)
    }

    func testConnectedIdleWinsWhenBacklogIsZeroEvenWithWarmBytes() {
        XCTAssertEqual(
            Self.derive(
                tunnelState: .connected(localPort: 42, via: .lan),
                confirmedTransferCount: 2,
                recentBytesPerSecond: 128,
                backlogPending: 0,
                backlogFailed: 0
            ),
            .connectedIdle
        )
    }

    func testConnectedTransferringDerivesFromRecentBytesWithBacklog() {
        XCTAssertEqual(
            Self.derive(
                tunnelState: .connected(localPort: 42, via: .lan),
                recentBytesPerSecond: 128,
                backlogPending: 1
            ),
            .connectedTransferring
        )
    }

    func testConnectedTransferringDerivesFromConfirmedTaskWithZeroBytes() {
        XCTAssertEqual(
            Self.derive(
                tunnelState: .connected(localPort: 42, via: .lan),
                confirmedTransferCount: 1,
                recentBytesPerSecond: 0,
                backlogPending: 1
            ),
            .connectedTransferring
        )
    }

    func testConnectedWaitingWhenBacklogExistsWithoutConfirmedTransferOrBytes() {
        XCTAssertEqual(
            Self.derive(
                tunnelState: .connected(localPort: 42, via: .lan),
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 1
            ),
            .connectedWaiting
        )
    }

    func testOmiWatchAndImportAggregationCanDriveTransferring() {
        let confirmedCount = confirmedTransferCount(mobileSegment: 0, omi: 1, watch: 2, share: 3)
        XCTAssertEqual(confirmedCount, 6)
        XCTAssertEqual(
            Self.derive(
                tunnelState: .connected(localPort: 42, via: .lan),
                confirmedTransferCount: confirmedCount,
                recentBytesPerSecond: 0,
                backlogPending: 1
            ),
            .connectedTransferring
        )

        let recentBytes = recentBytesTotal(mobileSegment: 0, omi: 64, watch: 128, share: 256)
        XCTAssertEqual(recentBytes, 448)
        XCTAssertEqual(
            Self.derive(
                tunnelState: .connected(localPort: 42, via: .lan),
                confirmedTransferCount: 0,
                recentBytesPerSecond: recentBytes,
                backlogPending: 1
            ),
            .connectedTransferring
        )
    }

    func testBacklogFailedAlsoCountsAsWaitingWork() {
        XCTAssertEqual(
            Self.derive(
                tunnelState: .connected(localPort: 42, via: .lan),
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 1
            ),
            .connectedWaiting
        )
    }

    private static func derive(
        tunnelState: TunnelState,
        reconnectCountdown: Int? = nil,
        isNetworkSatisfied: Bool? = true,
        confirmedTransferCount: Int = 0,
        recentBytesPerSecond: Double = 0,
        backlogPending: Int = 0,
        backlogFailed: Int = 0
    ) -> ConnectionSyncStatus {
        ConnectionSyncStatus.derive(
            ConnectionSyncInputs(
                tunnelState: tunnelState,
                reconnectCountdown: reconnectCountdown,
                isNetworkSatisfied: isNetworkSatisfied,
                confirmedTransferCount: confirmedTransferCount,
                recentBytesPerSecond: recentBytesPerSecond,
                backlogPending: backlogPending,
                backlogFailed: backlogFailed
            )
        )
    }
}
