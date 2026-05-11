// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel

enum CFTunnelTransportError: Error, Sendable, Equatable {
    case missingPairing
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
    private var session: TunnelSession?
    @ObservationIgnored
    private var proxy: LoopbackProxy?
    @ObservationIgnored
    private var stateTask: Task<Void, Never>?
    @ObservationIgnored
    private var connectionModeTask: Task<Void, Never>?

    init(
        appConfig: AppConfig? = nil,
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLKeychain.load() }
    ) {
        self.appConfig = appConfig
        self.loadPairing = loadPairing
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

        let session = TunnelSession(pairing: pairing)
        self.session = session
        observe(session: session, onDisconnect: onDisconnect, onStageChange: onStageChange)
        observeConnectionModeUpdates(session.connectionModeUpdates)

        onStageChange(.racing)
        _ = try await session.connect(endpoints: candidates)
        self.connectionMode = await session.connectionMode
        onStageChange(.tlsHandshaking)
        onStageChange(.muxReady)

        let proxy = LoopbackProxy(tunnel: session)
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
        session: TunnelSession,
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) {
        stateTask?.cancel()
        stateTask = Task {
            for await state in session.stateUpdates {
                switch state {
                case .disconnected:
                    onDisconnect(nil)
                case .failed(let error):
                    onStageChange(.failed(String(describing: error)))
                case .connecting, .tlsHandshaking, .connected:
                    break
                }
            }
        }
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
