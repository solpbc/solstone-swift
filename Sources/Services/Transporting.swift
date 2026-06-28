// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

@MainActor
public protocol Transporting: Sendable {
    var connectionMode: ConnectionMode? { get }

    func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int

    func disconnect() async
    func inboundActivitySnapshot() async -> UInt64
}

public enum TransportStage: Sendable, Equatable {
    case preparingCandidates
    case racing
    case tlsHandshaking
    case muxReady
    case loopbackReady(port: Int)
    case failed(String)
}
