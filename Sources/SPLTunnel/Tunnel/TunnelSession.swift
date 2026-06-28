// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "session")

public enum ConnectedVia: Sendable, Equatable {
    case lanDirect(host: String, port: Int)
    case relay(endpoint: URL)
}

public enum ConnectionMode: Sendable, Equatable {
    case plDirect
    case plViaSpl
}

public enum SessionError: Error, Equatable, Sendable {
    case notConnected
    case unreachable
    case directKeepaliveMissed
    case invalidRelayURL(String)
    case transportFailed(String)
    case tlsFailed(String)
    case revoked
    case tokenExpired
}

public enum TunnelState: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int, candidates: [TransportEndpoint])
    case tlsHandshaking(via: ConnectedVia)
    case awaitingBroker(via: ConnectedVia)
    case connected(via: ConnectedVia)
    case failed(SessionError)
}

public protocol TunnelSessioning: Sendable {
    nonisolated var stateUpdates: AsyncStream<TunnelState> { get }
    nonisolated var connectionModeUpdates: AsyncStream<ConnectionMode?> { get }
    var connectionMode: ConnectionMode? { get async }

    @discardableResult
    func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia
    func disconnect() async
    func openStream() async throws -> MuxStream
    func inboundActivitySnapshot() async -> UInt64
}

protocol TunnelTLSIO: Sendable {
    nonisolated var inbound: AsyncThrowingStream<Data, Error> { get }

    func send(_ data: Data) async throws
    func close() async
}

extension InnerTLS: TunnelTLSIO {}

typealias TunnelTLSConnector = @Sendable (
    TransportEndpoint,
    StoredPairing,
    @Sendable (ConnectedVia) async -> Void
) async throws -> any TunnelTLSIO

public actor TunnelSession: TunnelSessioning {
    public nonisolated var stateUpdates: AsyncStream<TunnelState> {
        stateStream
    }

    public nonisolated var connectionModeUpdates: AsyncStream<ConnectionMode?> {
        connectionModeStream
    }

    public private(set) var connectionMode: ConnectionMode?

    private let pairing: StoredPairing
    private let stateStream: AsyncStream<TunnelState>
    private let stateContinuation: AsyncStream<TunnelState>.Continuation
    private let connectionModeStream: AsyncStream<ConnectionMode?>
    private let connectionModeContinuation: AsyncStream<ConnectionMode?>.Continuation
    private let tlsConnector: TunnelTLSConnector
    private var state: TunnelState = .disconnected
    private var inboundPumpTask: Task<Void, Never>?
    private var inboundPumpID: UUID?
    private var keepaliveWatchTask: Task<Void, Never>?
    private var innerTLS: (any TunnelTLSIO)?
    private var multiplexer: Multiplexer?

    public init(pairing: StoredPairing) {
        self.init(pairing: pairing, tlsConnector: Self.defaultTLSConnector)
    }

    init(pairing: StoredPairing, tlsConnector: @escaping TunnelTLSConnector) {
        self.pairing = pairing
        self.tlsConnector = tlsConnector
        var continuation: AsyncStream<TunnelState>.Continuation!
        self.stateStream = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
        var modeContinuation: AsyncStream<ConnectionMode?>.Continuation!
        self.connectionModeStream = AsyncStream { modeContinuation = $0 }
        self.connectionModeContinuation = modeContinuation
        continuation.yield(.disconnected)
        modeContinuation.yield(nil)
    }

    @discardableResult
    public func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia {
        guard !endpoints.isEmpty else {
            throw SessionError.unreachable
        }
        guard case .disconnected = state else {
            if case .connected(let via) = state {
                return via
            }
            throw SessionError.transportFailed("connect already in progress")
        }

        let connected = try await connectOnce(attempt: 1, endpoints: endpoints)
        await installConnected(connected)
        return connected.via
    }

    public func disconnect() async {
        await tearDownCurrent(reason: .normalShutdown)
        setConnectionMode(nil)
        publish(.disconnected)
        stateContinuation.finish()
        connectionModeContinuation.finish()
    }

    public func openStream() async throws -> MuxStream {
        guard case .connected = state, let multiplexer else {
            throw SessionError.notConnected
        }
        return try await multiplexer.openStream()
    }

    public func inboundActivitySnapshot() async -> UInt64 {
        guard let multiplexer else {
            return 0
        }
        return await multiplexer.inboundActivitySnapshot()
    }

    private func connectOnce(attempt: Int, endpoints: [TransportEndpoint]) async throws -> ConnectedAttempt {
        publish(.connecting(attempt: attempt, candidates: endpoints))

        do {
            let result = try await RaceCoordinator<ConnectedAttempt>(close: { await $0.tls.close() }) { endpoint, progress in
                try await self.connectEndpoint(endpoint, attempt: attempt, progress: progress)
            }.connect(endpoints: endpoints)
            publishConnected(result.value, endpoint: result.endpoint)
            return result.value
        } catch let error as SessionError {
            publish(.failed(error))
            throw error
        } catch DialError.relayUnauthorized {
            publish(.failed(.revoked))
            throw SessionError.revoked
        } catch {
            let sessionError = SessionError.transportFailed(error.localizedDescription)
            publish(.failed(sessionError))
            throw sessionError
        }
    }

    private func connectEndpoint(
        _ endpoint: TransportEndpoint,
        attempt: Int,
        progress: RaceAttemptProgress
    ) async throws -> ConnectedAttempt {
        let via = endpoint.connectedVia
        publish(.tlsHandshaking(via: via))
        let startedAt = ContinuousClock.now

        let tls = try await tlsConnector(endpoint, pairing) { waitingVia in
            progress.reportWaiting()
            await self.publishAwaitingBroker(via: waitingVia)
        }
        let transport = endpoint.isDirect ? "lan" : "relay"
        logger.debug("connected transport=\(transport, privacy: .public) attempt=\(attempt, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
        return ConnectedAttempt(via: via, tls: tls)
    }

    private func publishConnected(_ connected: ConnectedAttempt, endpoint: TransportEndpoint) {
        if endpoint.isDirect {
            setConnectionMode(.plDirect)
        } else {
            setConnectionMode(.plViaSpl)
        }
        publish(.connected(via: connected.via))
    }

    private func installConnected(_ connected: ConnectedAttempt) async {
        let tls = connected.tls
        innerTLS = tls
        let pumpID = UUID()
        inboundPumpID = pumpID
        let mux = Multiplexer { data in
            try await tls.send(data)
        }
        multiplexer = mux
        let pump = Task {
            do {
                for try await chunk in tls.inbound {
                    try await mux.feedInbound(chunk)
                }
                await self.handlePumpEnded(id: pumpID)
            } catch {
                await self.handlePumpEnded(id: pumpID)
            }
        }
        inboundPumpTask = pump

        if case .lanDirect = connected.via {
            await mux.startKeepalive()
            keepaliveWatchTask = Task { [mux] in
                for await _ in mux.keepaliveLost {
                    await self.handleDirectKeepaliveLost()
                    break
                }
            }
        }
    }

    private func handlePumpEnded(id: UUID) async {
        guard inboundPumpID == id, case .connected = state else {
            return
        }
        publish(.failed(.transportFailed("inbound closed")))
        await tearDownCurrent(reason: .transportFailure)
    }

    private func tearDownCurrent(reason: TearDownReason) async {
        inboundPumpID = nil
        keepaliveWatchTask?.cancel()
        keepaliveWatchTask = nil
        inboundPumpTask?.cancel()
        inboundPumpTask = nil
        await innerTLS?.close()
        innerTLS = nil
        await multiplexer?.tearDown(reason: reason)
        multiplexer = nil
        setConnectionMode(nil)
    }

    private func handleDirectKeepaliveLost() async {
        guard connectionMode == .plDirect else {
            return
        }
        publish(.failed(.directKeepaliveMissed))
        await tearDownCurrent(reason: .transportFailure)
    }

    private func publish(_ newState: TunnelState) {
        state = newState
        stateContinuation.yield(newState)
    }

    private func publishAwaitingBroker(via: ConnectedVia) {
        publish(.awaitingBroker(via: via))
    }

    private func setConnectionMode(_ newMode: ConnectionMode?) {
        connectionMode = newMode
        connectionModeContinuation.yield(newMode)
    }

    private static func defaultTLSConnector(
        endpoint: TransportEndpoint,
        pairing: StoredPairing,
        onAwaitingBroker: @Sendable (ConnectedVia) async -> Void
    ) async throws -> any TunnelTLSIO {
        switch endpoint {
        case .lan(let host, let port, _):
            return try await withSessionTimeout(.seconds(5)) {
                try await InnerTLS.connectLAN(host: host, port: port, pairing: pairing)
            }
        case .relay:
            let transport = try await DialClient.dial(endpoint, timeout: .seconds(5))
            await onAwaitingBroker(endpoint.connectedVia)
            return try await InnerTLS.connectViaTransport(transport: transport, pairing: pairing)
        }
    }
}

private struct ConnectedAttempt: Sendable {
    let via: ConnectedVia
    let tls: any TunnelTLSIO
}

private func withSessionTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SessionError.transportFailed("connect timeout")
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
