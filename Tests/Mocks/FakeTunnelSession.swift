// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel

actor FakeTunnelSession: TunnelSessioning, MuxStreamOpening, TunnelAttemptObserving {
    nonisolated let stateUpdates: AsyncStream<TunnelState>
    nonisolated let connectionModeUpdates: AsyncStream<ConnectionMode?>
    nonisolated let attemptUpdates: AsyncStream<TunnelAttemptEvent>

    private let stateContinuation: AsyncStream<TunnelState>.Continuation
    private let connectionModeContinuation: AsyncStream<ConnectionMode?>.Continuation
    private let attemptUpdatesContinuation: AsyncStream<TunnelAttemptEvent>.Continuation
    private let connectedVia: ConnectedVia
    private let connectedMode: ConnectionMode
    private let yieldAwaitingBrokerDuringConnect: Bool
    private let finishAttemptUpdatesAfterConnect: Bool
    private var failureDuringConnect: SessionError?
    private var thrownDuringConnect: (any Error & Sendable)?
    private var attemptsOnDisconnect: [TunnelAttemptEvent] = []
    private var inboundActivitySnapshotValue: UInt64 = 0
    private(set) var connectionMode: ConnectionMode?
    private let suspendConnect: Bool
    private let suspendDisconnect: Bool
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    init(
        connectedVia: ConnectedVia = .lanDirect(host: "127.0.0.1", port: 8676),
        connectedMode: ConnectionMode = .plDirect,
        failureDuringConnect: SessionError? = nil,
        thrownDuringConnect: (any Error & Sendable)? = nil,
        yieldAwaitingBrokerDuringConnect: Bool = false,
        finishAttemptUpdatesAfterConnect: Bool = true,
        suspendConnect: Bool = false,
        suspendDisconnect: Bool = false
    ) {
        let state = AsyncStream<TunnelState>.makeStream()
        self.stateUpdates = state.stream
        self.stateContinuation = state.continuation
        let mode = AsyncStream<ConnectionMode?>.makeStream()
        self.connectionModeUpdates = mode.stream
        self.connectionModeContinuation = mode.continuation
        let attempts = AsyncStream<TunnelAttemptEvent>.makeStream()
        self.attemptUpdates = attempts.stream
        self.attemptUpdatesContinuation = attempts.continuation
        self.suspendConnect = suspendConnect
        self.suspendDisconnect = suspendDisconnect
        self.connectedVia = connectedVia
        self.connectedMode = connectedMode
        self.yieldAwaitingBrokerDuringConnect = yieldAwaitingBrokerDuringConnect
        self.finishAttemptUpdatesAfterConnect = finishAttemptUpdatesAfterConnect
        self.failureDuringConnect = failureDuringConnect
        self.thrownDuringConnect = thrownDuringConnect
    }

    @discardableResult
    func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia {
        connectCallCount += 1
        if suspendConnect { await withCheckedContinuation { connectContinuation = $0 } }
        stateContinuation.yield(.connecting(candidates: endpoints.map(\.connectedVia)))
        if let failureDuringConnect {
            stateContinuation.yield(.failed(failureDuringConnect))
            try await Task.sleep(for: .milliseconds(200))
        }
        if let thrownDuringConnect {
            throw thrownDuringConnect
        }
        if yieldAwaitingBrokerDuringConnect {
            stateContinuation.yield(.awaitingBroker(via: connectedVia))
        }
        connectionMode = connectedMode
        connectionModeContinuation.yield(connectedMode)
        stateContinuation.yield(.connected(via: connectedVia))
        if finishAttemptUpdatesAfterConnect {
            attemptUpdatesContinuation.finish()
        }
        return connectedVia
    }

    func disconnect() async {
        disconnectCallCount += 1
        if suspendDisconnect { await withCheckedContinuation { disconnectContinuation = $0 } }
        connectionMode = nil
        connectionModeContinuation.yield(nil)
        stateContinuation.yield(.disconnected)
        stateContinuation.finish()
        connectionModeContinuation.finish()
        for event in attemptsOnDisconnect {
            attemptUpdatesContinuation.yield(event)
        }
        attemptUpdatesContinuation.finish()
    }

    func releaseConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func releaseDisconnect() {
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }

    func openStream() async throws -> MuxStream {
        throw SessionError.notConnected
    }

    func inboundActivitySnapshot() async -> UInt64 {
        inboundActivitySnapshotValue
    }

    func setInboundActivitySnapshot(_ value: UInt64) {
        inboundActivitySnapshotValue = value
    }

    func failWithinConnect(_ error: SessionError) {
        failureDuringConnect = error
    }

    func throwWithinConnect(_ error: any Error & Sendable) {
        thrownDuringConnect = error
    }

    func pushFailed(_ error: SessionError) {
        stateContinuation.yield(.failed(error))
    }

    func pushDisconnected() {
        stateContinuation.yield(.disconnected)
    }

    func pushAttempt(_ event: TunnelAttemptEvent) {
        attemptUpdatesContinuation.yield(event)
    }

    func finishAttemptUpdates() {
        attemptUpdatesContinuation.finish()
    }

    func pushAttemptOnDisconnect(_ event: TunnelAttemptEvent) {
        attemptsOnDisconnect.append(event)
    }
}
