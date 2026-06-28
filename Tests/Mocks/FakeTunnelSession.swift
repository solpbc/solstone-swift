// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel

actor FakeTunnelSession: TunnelSessioning {
    nonisolated let stateUpdates: AsyncStream<TunnelState>
    nonisolated let connectionModeUpdates: AsyncStream<ConnectionMode?>

    private let stateContinuation: AsyncStream<TunnelState>.Continuation
    private let connectionModeContinuation: AsyncStream<ConnectionMode?>.Continuation
    private let connectedVia: ConnectedVia
    private let connectedMode: ConnectionMode
    private var failureDuringConnect: SessionError?
    private var inboundActivitySnapshotValue: UInt64 = 0
    private(set) var connectionMode: ConnectionMode?
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    init(
        connectedVia: ConnectedVia = .lanDirect(host: "127.0.0.1", port: 8676),
        connectedMode: ConnectionMode = .plDirect,
        failureDuringConnect: SessionError? = nil
    ) {
        let state = AsyncStream<TunnelState>.makeStream()
        self.stateUpdates = state.stream
        self.stateContinuation = state.continuation
        let mode = AsyncStream<ConnectionMode?>.makeStream()
        self.connectionModeUpdates = mode.stream
        self.connectionModeContinuation = mode.continuation
        self.connectedVia = connectedVia
        self.connectedMode = connectedMode
        self.failureDuringConnect = failureDuringConnect
    }

    @discardableResult
    func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia {
        connectCallCount += 1
        stateContinuation.yield(.connecting(attempt: connectCallCount, candidates: endpoints))
        if let failureDuringConnect {
            stateContinuation.yield(.failed(failureDuringConnect))
            try await Task.sleep(for: .milliseconds(200))
        }
        connectionMode = connectedMode
        connectionModeContinuation.yield(connectedMode)
        stateContinuation.yield(.connected(via: connectedVia))
        return connectedVia
    }

    func disconnect() async {
        disconnectCallCount += 1
        connectionMode = nil
        connectionModeContinuation.yield(nil)
        stateContinuation.yield(.disconnected)
        stateContinuation.finish()
        connectionModeContinuation.finish()
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

    func pushFailed(_ error: SessionError) {
        stateContinuation.yield(.failed(error))
    }

    func pushDisconnected() {
        stateContinuation.yield(.disconnected)
    }
}
