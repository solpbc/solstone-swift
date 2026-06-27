// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel

@MainActor
final class MockCFTunnelTransport: Transporting {
    enum QueuedResult: Sendable {
        case success(Int)
        case failure(any Error & Sendable)
    }

    var connectionMode: ConnectionMode? = nil
    var nextResult: Result<Int, TunnelError> = .success(54321)
    var queuedResults: [QueuedResult] = []
    var capturedCandidates: [TransportEndpoint] = []
    var capturedCandidateBatches: [[TransportEndpoint]] = []
    var onDisconnectCallback: (@Sendable (Error?) -> Void)?
    var connectCallCount = 0
    var disconnectCallCount = 0
    var stageEvents: [TransportStage] = []
    var connectDelay: Duration?
    var suspendConnectUntilDisconnect = false
    var returnedPort: Int?
    var onDisconnectInvoked: (() -> Void)?
    private var suspendedConnect: CheckedContinuation<Int, Error>?

    func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int {
        connectCallCount += 1
        capturedCandidates = candidates
        capturedCandidateBatches.append(candidates)
        onDisconnectCallback = onDisconnect
        for stage in [TransportStage.preparingCandidates, .racing, .tlsHandshaking, .muxReady] {
            stageEvents.append(stage)
            onStageChange(stage)
        }
        if suspendConnectUntilDisconnect {
            return try await withCheckedThrowingContinuation { continuation in
                suspendedConnect = continuation
            }
        }
        if let connectDelay {
            try? await Task.sleep(for: connectDelay)
        }
        let result: QueuedResult
        if queuedResults.isEmpty {
            switch nextResult {
            case .success(let port):
                result = .success(port)
            case .failure(let error):
                result = .failure(error)
            }
        } else {
            result = queuedResults.removeFirst()
        }

        switch result {
        case .success(let port):
            let ready = TransportStage.loopbackReady(port: port)
            stageEvents.append(ready)
            onStageChange(ready)
            returnedPort = port
            return port
        case .failure(let error):
            let failed = TransportStage.failed((error as? TunnelError)?.userMessage ?? String(describing: error))
            stageEvents.append(failed)
            onStageChange(failed)
            throw error
        }
    }

    func disconnect() async {
        disconnectCallCount += 1
        onDisconnectInvoked?()
        guard let continuation = suspendedConnect else {
            return
        }
        suspendedConnect = nil
        continuation.resume(throwing: SessionError.transportFailed("watchdog test"))
    }

    func simulateDisconnect(error: Error? = nil) {
        onDisconnectCallback?(error)
    }
}
