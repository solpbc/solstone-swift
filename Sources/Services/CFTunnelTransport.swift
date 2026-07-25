// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel

enum CFTunnelTransportError: Error, Sendable, Equatable {
    case missingPairing
}

private enum ConnectStartupRaceResult: Sendable {
    case port(Int)
    case terminal(SessionError)
    case windowClosed
}

private actor ConnectWindowTerminalSignal {
    private enum Phase: Equatable {
        case openUnarmed
        case openArmed
        case resolved
        case closed
    }

    private var phase: Phase = .openUnarmed
    private let stream: AsyncStream<SessionError>
    private let continuation: AsyncStream<SessionError>.Continuation

    init() {
        let terminal = AsyncStream<SessionError>.makeStream()
        self.stream = terminal.stream
        self.continuation = terminal.continuation
    }

    func observe(_ state: SPLTunnel.TunnelState) -> Bool {
        switch phase {
        case .closed:
            return false
        case .resolved:
            return true
        case .openUnarmed:
            switch state {
            case .connecting, .tlsHandshaking, .awaitingBroker, .connected:
                phase = .openArmed
                return false
            case .disconnected, .failed:
                return true
            }
        case .openArmed:
            switch state {
            case .disconnected:
                resolve(.transportFailed("session disconnected during connect"))
                return true
            case .failed(let error):
                resolve(error)
                return true
            case .connecting, .tlsHandshaking, .awaitingBroker, .connected:
                return false
            }
        }
    }

    func waitForTerminal() async -> SessionError? {
        for await error in stream {
            return error
        }
        return nil
    }

    func close() {
        guard phase != .closed else {
            return
        }
        phase = .closed
        continuation.finish()
    }

    private func resolve(_ error: SessionError) {
        guard phase != .resolved, phase != .closed else {
            return
        }
        phase = .resolved
        continuation.yield(error)
        continuation.finish()
    }
}

@MainActor
@Observable
final class CFTunnelTransport: Transporting {
    public private(set) var connectionMode: ConnectionMode?
    @ObservationIgnored
    private let appConfig: AppConfig?
    @ObservationIgnored
    private let loadPairing: @Sendable () throws -> StoredPairing?
    @ObservationIgnored
    private let makeSession: @Sendable (StoredPairing) -> any TunnelSessioning & MuxStreamOpening

    @ObservationIgnored
    private var session: (any TunnelSessioning & MuxStreamOpening)?
    @ObservationIgnored
    private var proxy: LoopbackProxy?
    @ObservationIgnored
    private var stateTask: Task<Void, Never>?
    @ObservationIgnored
    private var connectionModeTask: Task<Void, Never>?

    init(
        appConfig: AppConfig? = nil,
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLRuntime.keychainStore.load() },
        makeSession: @escaping @Sendable (StoredPairing) -> any TunnelSessioning & MuxStreamOpening = {
            TunnelSession(
                pairing: $0,
                clientInfo: SPLRuntime.clientInfo,
                policy: SessionPolicy(
                    keepalive: KeepalivePolicy(
                        interval: .milliseconds(500),
                        idleThreshold: .seconds(2),
                        missedLimit: 3,
                        runsOnRelayPath: false
                    )
                )
            )
        }
    ) {
        self.appConfig = appConfig
        self.loadPairing = loadPairing
        self.makeSession = makeSession
    }

    public func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int {
        onStageChange(.preparingCandidates)
        guard let pairing = try loadPairing() else {
            onStageChange(.failed("missing pairing"))
            throw CFTunnelTransportError.missingPairing
        }

        let session = makeSession(pairing)
        self.session = session
        let connectWindow = ConnectWindowTerminalSignal()
        observe(
            session: session,
            onDisconnect: onDisconnect,
            onStageChange: onStageChange,
            connectWindow: connectWindow
        )
        observeConnectionModeUpdates(session.connectionModeUpdates)

        do {
            let port = try await raceStartupAgainstConnectWindow(
                session: session,
                candidates: candidates,
                onStageChange: onStageChange,
                connectWindow: connectWindow
            )
            await connectWindow.close()
            return port
        } catch {
            await connectWindow.close()
            throw error
        }
    }

    private func raceStartupAgainstConnectWindow(
        session: any TunnelSessioning & MuxStreamOpening,
        candidates: [TransportEndpoint],
        onStageChange: @Sendable @escaping (TransportStage) -> Void,
        connectWindow: ConnectWindowTerminalSignal
    ) async throws -> Int {
        let startupTask = Task { @MainActor in
            try await self.startSessionAndProxy(
                session: session,
                candidates: candidates,
                onStageChange: onStageChange
            )
        }
        let terminalTask = Task {
            await connectWindow.waitForTerminal()
        }
        defer {
            startupTask.cancel()
            terminalTask.cancel()
        }

        return try await withThrowingTaskGroup(of: ConnectStartupRaceResult.self) { group in
            group.addTask {
                .port(try await startupTask.value)
            }
            group.addTask {
                guard let error = await terminalTask.value else {
                    return .windowClosed
                }
                return .terminal(error)
            }

            do {
                while let result = try await group.next() {
                    switch result {
                    case .port(let port):
                        await connectWindow.close()
                        terminalTask.cancel()
                        group.cancelAll()
                        return port
                    case .terminal(let error):
                        startupTask.cancel()
                        await connectWindow.close()
                        group.cancelAll()
                        throw error
                    case .windowClosed:
                        continue
                    }
                }
            } catch {
                await connectWindow.close()
                throw error
            }
            throw CancellationError()
        }
    }

    private func startSessionAndProxy(
        session: any TunnelSessioning & MuxStreamOpening,
        candidates: [TransportEndpoint],
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int {
        onStageChange(.racing)
        _ = try await session.connect(endpoints: candidates)
        self.connectionMode = await session.connectionMode
        onStageChange(.tlsHandshaking)
        onStageChange(.muxReady)

        let proxy = LoopbackProxy(opener: session)
        self.proxy = proxy
        let port = Int(try await proxy.start())
        onStageChange(.loopbackReady(port: port))
        return port
    }

    public func disconnect() async {
        stateTask?.cancel()
        stateTask = nil
        connectionModeTask?.cancel()
        connectionModeTask = nil
        await proxy?.stop()
        proxy = nil
        await session?.disconnect()
        session = nil
        connectionMode = nil
    }

    private func observe(
        session: any TunnelSessioning,
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void,
        connectWindow: ConnectWindowTerminalSignal? = nil
    ) {
        stateTask?.cancel()
        stateTask = Task { @MainActor in
            for await state in session.stateUpdates {
                if let connectWindow, await connectWindow.observe(state) {
                    continue
                }
                switch state {
                case .disconnected:
                    onDisconnect(nil)
                case .failed(let error):
                    onDisconnect(error)
                case .awaitingBroker:
                    onStageChange(.awaitingBroker)
                case .connecting, .tlsHandshaking, .connected:
                    break
                }
            }
        }
    }

    public func inboundActivitySnapshot() async -> UInt64 {
        guard let session else {
            return 0
        }
        return await session.inboundActivitySnapshot()
    }

    func observeConnectionModeUpdates(_ updates: AsyncStream<ConnectionMode?>) {
        connectionModeTask?.cancel()
        connectionModeTask = Task { @MainActor [weak self] in
            for await mode in updates {
                self?.connectionMode = mode
            }
        }
    }
}
