// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

enum CFTunnelTransportError: Error, Sendable, Equatable {
    case missingPairing
}

@MainActor
final class CFTunnelTransport: Transporting {
    public private(set) var connectionMode: ConnectionMode?
    private let appConfig: AppConfig?

    private var session: TunnelSession?
    private var proxy: LoopbackProxy?
    private var stateTask: Task<Void, Never>?

    init(appConfig: AppConfig? = nil) {
        self.appConfig = appConfig
    }

    public func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int {
        onStageChange(.preparingCandidates)
        guard let pairing = try SPLKeychain.load() else {
            onStageChange(.failed("missing pairing"))
            throw CFTunnelTransportError.missingPairing
        }

        let session = TunnelSession(pairing: pairing)
        self.session = session
        observe(session: session, onDisconnect: onDisconnect, onStageChange: onStageChange)

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
}
