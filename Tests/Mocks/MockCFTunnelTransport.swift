// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel

@MainActor
final class MockCFTunnelTransport: Transporting {
    var connectionMode: ConnectionMode? = nil
    var nextResult: Result<Int, TunnelError> = .success(54321)
    var capturedCandidates: [TransportEndpoint] = []
    var onDisconnectCallback: (@Sendable (Error?) -> Void)?
    var connectCallCount = 0
    var disconnectCallCount = 0
    var stageEvents: [TransportStage] = []
    var connectDelay: Duration?

    func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int {
        connectCallCount += 1
        capturedCandidates = candidates
        onDisconnectCallback = onDisconnect
        for stage in [TransportStage.preparingCandidates, .racing, .tlsHandshaking, .muxReady] {
            stageEvents.append(stage)
            onStageChange(stage)
        }
        if let connectDelay {
            try? await Task.sleep(for: connectDelay)
        }
        switch nextResult {
        case .success(let port):
            let ready = TransportStage.loopbackReady(port: port)
            stageEvents.append(ready)
            onStageChange(ready)
            return port
        case .failure(let error):
            let failed = TransportStage.failed(error.userMessage)
            stageEvents.append(failed)
            onStageChange(failed)
            throw error
        }
    }

    func disconnect() async {
        disconnectCallCount += 1
    }

    func simulateDisconnect(error: Error? = nil) {
        onDisconnectCallback?(error)
    }
}
