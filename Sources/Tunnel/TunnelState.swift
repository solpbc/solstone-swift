// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ConnectionEndpoint: Sendable {
    case lan
    case remote
}

enum TunnelState: Sendable, Equatable, CustomStringConvertible {
    case disconnected
    case connecting
    case waitingForHome
    case connected(localPort: Int, via: ConnectionEndpoint)
    case error(TunnelError)

    var description: String {
        switch self {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .waitingForHome: "waitingForHome"
        case .connected(let port, let ep): "connected(port:\(port), \(ep))"
        case .error(let err): "error(\(err))"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum ConnectionStageKind: String, Sendable, Equatable {
    case prepareCandidates
    case raceCandidates
    case tlsHandshake
    case muxReady
    case loopback
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
