// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner-facing connection/sync state and its functional lowercase-first default copy.
///
/// The string table below is that functional lowercase-first default, until a product
/// voice and visuals pass lands.
nonisolated enum ConnectionSyncStatus: Equatable, Sendable {
    case offline
    case connecting
    case waitingForHome
    case reconnecting
    case unreachable
    case connectedIdle
    case connectedWaiting
    case connectedTransferring

    nonisolated var statusLine: String {
        switch self {
        case .offline:
            "offline"
        case .connecting:
            "connecting…"
        case .waitingForHome:
            "waiting for your journal…"
        case .reconnecting:
            "reconnecting…"
        case .unreachable:
            "can't reach your journal"
        case .connectedIdle:
            "connected"
        case .connectedWaiting:
            "connected · waiting to sync"
        case .connectedTransferring:
            "connected · syncing"
        }
    }

    /// What the transport reports right now. Whether the journal has been heard from
    /// recently enough to *show* connected is `ConnectionPresenter`'s call, not this one's.
    nonisolated static func derive(_ inputs: ConnectionSyncInputs) -> ConnectionSyncStatus {
        switch inputs.tunnelState {
        case .disconnected:
            return .offline
        case .connected:
            // A path reading alone never withdraws a tunnel the journal is still answering on:
            // the presenter's lease does that, from evidence.
            let backlog = inputs.backlogPending + inputs.backlogFailed
            if backlog == 0 {
                return .connectedIdle
            }
            let transferActive = inputs.recentBytesPerSecond > 0 || inputs.confirmedTransferCount > 0
            return transferActive ? .connectedTransferring : .connectedWaiting
        case .connecting:
            return inputs.isNetworkSatisfied == false ? .offline : .connecting
        case .waitingForHome:
            return inputs.isNetworkSatisfied == false ? .offline : .waitingForHome
        case .error(let error):
            if inputs.isNetworkSatisfied == false {
                return .offline
            }
            return error.isRetryable && inputs.reconnectCountdown != nil ? .reconnecting : .unreachable
        }
    }
}

nonisolated struct ConnectionSyncInputs: Sendable {
    let tunnelState: TunnelState
    let reconnectCountdown: Int?
    let isNetworkSatisfied: Bool?
    let confirmedTransferCount: Int
    let recentBytesPerSecond: Double
    let backlogPending: Int
    let backlogFailed: Int
    /// When the journal last answered on the current connection: the handshake, a probe,
    /// inbound bytes or an acknowledged transfer. Nil once the connection is gone.
    let lastHeardAt: Date?
    /// What the home pill counts as waiting (capture sources), for the syncing linger.
    let captureBacklog: Int

    nonisolated init(
        tunnelState: TunnelState,
        reconnectCountdown: Int?,
        isNetworkSatisfied: Bool?,
        confirmedTransferCount: Int,
        recentBytesPerSecond: Double,
        backlogPending: Int,
        backlogFailed: Int,
        lastHeardAt: Date? = nil,
        captureBacklog: Int = 0
    ) {
        self.tunnelState = tunnelState
        self.reconnectCountdown = reconnectCountdown
        self.isNetworkSatisfied = isNetworkSatisfied
        self.confirmedTransferCount = confirmedTransferCount
        self.recentBytesPerSecond = recentBytesPerSecond
        self.backlogPending = backlogPending
        self.backlogFailed = backlogFailed
        self.lastHeardAt = lastHeardAt
        self.captureBacklog = captureBacklog
    }
}

nonisolated func isJournalReachable(_ status: ConnectionSyncStatus) -> Bool {
    switch status {
    case .connectedIdle, .connectedWaiting, .connectedTransferring:
        return true
    case .offline, .connecting, .waitingForHome, .reconnecting, .unreachable:
        return false
    }
}
