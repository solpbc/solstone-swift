// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum ConnectionEndpoint: Sendable {
    case lan
    case remote
}

enum TunnelState: Sendable, Equatable, CustomStringConvertible {
    case disconnected
    case connecting(ConnectionEndpoint)
    case connected(localPort: Int, via: ConnectionEndpoint)
    case error(TunnelError)

    var description: String {
        switch self {
        case .disconnected: "disconnected"
        case .connecting(let ep): "connecting(\(ep))"
        case .connected(let port, let ep): "connected(port:\(port), \(ep))"
        case .error(let err): "error(\(err))"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum ConnectionHealth: Sendable, Equatable {
    case healthy
    case degraded
    case unknown
}

enum ConnectionStageKind: String, Sendable, Equatable {
    case lanProbe
    case sshConnect
    case startHubPhone
    case portForward
    case connected
}

enum ConnectionStageStatus: Sendable, Equatable {
    case active
    case done
    case failed
}

struct ConnectionStage: Identifiable, Sendable {
    let id: ConnectionStageKind
    var kind: ConnectionStageKind { id }
    var status: ConnectionStageStatus
    var duration: TimeInterval?
    var detail: String?
    var attemptCount: Int?
    var startTime: ContinuousClock.Instant?
}

enum SSHStageEvent: Sendable {
    case sshConnecting
    case sshConnected
    case startingHubPhone
    case hubPhoneReady(port: Int)
    case portForwarding
    case execOutput(String, isStdErr: Bool)
    case execFailed(stderr: String)
}
