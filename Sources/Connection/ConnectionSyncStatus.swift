// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// VPX handoff artifact for owner-facing connection/sync state and default copy.
///
/// VPX owns final strings and visuals. The string table below is the functional
/// lowercase-first default used until that pass lands.
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
            "waiting for your home…"
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

    nonisolated static func derive(_ inputs: ConnectionSyncInputs) -> ConnectionSyncStatus {
        if case .disconnected = inputs.tunnelState {
            return .offline
        }
        if inputs.isNetworkSatisfied == false {
            return .offline
        }

        switch inputs.tunnelState {
        case .disconnected:
            return .offline
        case .connecting:
            return .connecting
        case .waitingForHome:
            return .waitingForHome
        case .error(let error):
            return error.isRetryable && inputs.reconnectCountdown != nil ? .reconnecting : .unreachable
        case .connected:
            let backlog = inputs.backlogPending + inputs.backlogFailed
            if backlog == 0 {
                return .connectedIdle
            }
            let transferActive = inputs.recentBytesPerSecond > 0 || inputs.confirmedTransferCount > 0
            return transferActive ? .connectedTransferring : .connectedWaiting
        }
    }

    nonisolated static func isNetworkBlipWhileTunnelConnected(
        inputs: ConnectionSyncInputs,
        derived: ConnectionSyncStatus
    ) -> Bool {
        guard !isJournalReachable(derived), inputs.isNetworkSatisfied == false else {
            return false
        }
        if case .connected = inputs.tunnelState {
            return true
        }
        return false
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
}

nonisolated func isJournalReachable(_ status: ConnectionSyncStatus) -> Bool {
    switch status {
    case .connectedIdle, .connectedWaiting, .connectedTransferring:
        return true
    case .offline, .connecting, .waitingForHome, .reconnecting, .unreachable:
        return false
    }
}

nonisolated func statusPaneRegion(_ status: ConnectionSyncStatus) -> (id: String, value: String) {
    if isJournalReachable(status) {
        return ("shell.pane.status.connected", status.statusLine)
    }
    return ("shell.pane.status.degraded", status.statusLine)
}
