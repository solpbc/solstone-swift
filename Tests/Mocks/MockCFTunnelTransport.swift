// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel

@MainActor
final class MockCFTunnelTransport: Transporting {
    enum Operation: Equatable {
        case connect(Int)
        case disconnect(Int)
        case suspendedConnectFinished(Int)
    }
    enum QueuedResult: Sendable {
        case success(Int)
        case failure(any Error & Sendable)
    }

    var connectionMode: ConnectionMode? = nil
    var generationSnapshot = TransportGenerationSnapshot(currentGeneration: 0, activeGeneration: nil, lastClosedGeneration: nil)
    var nextResult: Result<Int, TunnelError> = .success(54321)
    var queuedResults: [QueuedResult] = []
    var capturedCandidates: [TransportEndpoint] = []
    var capturedCandidateBatches: [[TransportEndpoint]] = []
    var onDisconnectCallback: (@Sendable (Error?) -> Void)?
    var connectCallCount = 0
    var disconnectCallCount = 0
    var stageEvents: [TransportStage] = []
    var operations: [Operation] = []
    var connectDelay: Duration?
    var suspendConnectUntilDisconnect = false
    var emitAwaitingBrokerBeforeResult = false
    var upstreamFailureBeforeAwaitingBroker: String?
    var suspendAfterAwaitingBroker = false
    var returnedPort: Int?
    var onDisconnectInvoked: (() -> Void)?
    var inboundActivitySnapshotValue: UInt64 = 0
    var inboundActivitySnapshots: [UInt64] = []
    private var suspendedConnects: [Int: CheckedContinuation<Int, Error>] = [:]
    private var disconnectCallbacks: [Int: @Sendable (Error?) -> Void] = [:]
    private var stageCallbacks: [Int: @Sendable (TransportStage) -> Void] = [:]

    func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int {
        connectCallCount += 1
        let attempt = connectCallCount
        operations.append(.connect(attempt))
        capturedCandidates = candidates
        capturedCandidateBatches.append(candidates)
        onDisconnectCallback = onDisconnect
        disconnectCallbacks[attempt] = onDisconnect
        stageCallbacks[attempt] = onStageChange
        let initialStages: [TransportStage] = emitAwaitingBrokerBeforeResult
            ? [.preparingCandidates, .racing]
            : [.preparingCandidates, .racing, .tlsHandshaking, .muxReady]
        for stage in initialStages {
            stageEvents.append(stage)
            onStageChange(stage)
        }
        if emitAwaitingBrokerBeforeResult {
            if let upstreamFailureBeforeAwaitingBroker {
                let failed = TransportStage.failed(upstreamFailureBeforeAwaitingBroker)
                stageEvents.append(failed)
                onStageChange(failed)
            }
            stageEvents.append(.awaitingBroker)
            onStageChange(.awaitingBroker)
        }
        if suspendAfterAwaitingBroker {
            do {
                let port = try await withCheckedThrowingContinuation { continuation in
                    suspendedConnects[attempt] = continuation
                }
                operations.append(.suspendedConnectFinished(attempt))
                for stage in [TransportStage.tlsHandshaking, .muxReady] {
                    stageEvents.append(stage)
                    onStageChange(stage)
                }
                let ready = TransportStage.loopbackReady(port: port)
                stageEvents.append(ready)
                onStageChange(ready)
                returnedPort = port
                return port
            } catch {
                operations.append(.suspendedConnectFinished(attempt))
                throw error
            }
        }
        if suspendConnectUntilDisconnect {
            return try await withCheckedThrowingContinuation { continuation in
                suspendedConnects[attempt] = continuation
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
        operations.append(.disconnect(disconnectCallCount))
        onDisconnectInvoked?()
        guard let attempt = suspendedConnects.keys.min(), let continuation = suspendedConnects.removeValue(forKey: attempt) else {
            return
        }
        continuation.resume(throwing: SessionError.transportFailed("watchdog test"))
    }

    func inboundActivitySnapshot() async -> UInt64 {
        guard !inboundActivitySnapshots.isEmpty else {
            return inboundActivitySnapshotValue
        }
        inboundActivitySnapshotValue = inboundActivitySnapshots.removeFirst()
        return inboundActivitySnapshotValue
    }

    func simulateDisconnect(error: Error? = nil) {
        onDisconnectCallback?(error)
    }

    func simulateDisconnect(attempt: Int, error: Error? = nil) {
        disconnectCallbacks[attempt]?(error)
    }

    func emitStage(_ stage: TransportStage, attempt: Int) {
        stageEvents.append(stage)
        stageCallbacks[attempt]?(stage)
    }

    func completeSuspendedConnect(port: Int) {
        guard let attempt = suspendedConnects.keys.max() else {
            return
        }
        completeSuspendedConnect(attempt: attempt, port: port)
    }

    func completeSuspendedConnect(attempt: Int, port: Int) {
        guard let continuation = suspendedConnects.removeValue(forKey: attempt) else { return }
        continuation.resume(returning: port)
    }

    func failSuspendedConnect(error: any Error) {
        guard let attempt = suspendedConnects.keys.max() else {
            return
        }
        failSuspendedConnect(attempt: attempt, error: error)
    }

    func failSuspendedConnect(attempt: Int, error: any Error) {
        guard let continuation = suspendedConnects.removeValue(forKey: attempt) else { return }
        continuation.resume(throwing: error)
    }
}
