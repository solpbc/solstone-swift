// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

@MainActor
public protocol Transporting: Sendable {
    var connectionMode: ConnectionMode? { get }
    var generationSnapshot: TransportGenerationSnapshot { get }

    func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int

    func disconnect() async
    func inboundActivitySnapshot() async -> UInt64
}

public struct TransportGenerationSnapshot: Sendable, Equatable {
    public let currentGeneration: UInt64
    public let activeGeneration: UInt64?
    public let lastClosedGeneration: UInt64?

    public init(currentGeneration: UInt64, activeGeneration: UInt64?, lastClosedGeneration: UInt64?) {
        self.currentGeneration = currentGeneration
        self.activeGeneration = activeGeneration
        self.lastClosedGeneration = lastClosedGeneration
    }
}

public enum TransportStage: Sendable, Equatable {
    case preparingCandidates
    case racing
    case awaitingBroker
    case tlsHandshaking
    case muxReady
    case loopbackReady(port: Int)
    case failed(String)
}
