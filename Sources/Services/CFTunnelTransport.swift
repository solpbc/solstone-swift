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
    private static let defaultAttemptUpdatesDrainDeadline = Duration.seconds(2)

    public private(set) var connectionMode: ConnectionMode?
    public private(set) var generationSnapshot = TransportGenerationSnapshot(
        currentGeneration: 0,
        activeGeneration: nil,
        lastClosedGeneration: nil
    )
    @ObservationIgnored
    private let appConfig: AppConfig?
    @ObservationIgnored
    private let loadPairing: @Sendable () throws -> StoredPairing?
    @ObservationIgnored
    private let makeSession: @Sendable (StoredPairing) -> any TunnelSessioning & MuxStreamOpening

    @ObservationIgnored
    private var session: (any TunnelSessioning & MuxStreamOpening)?
    @ObservationIgnored
    private var sessionEpoch: UInt64 = 0
    @ObservationIgnored
    private var proxy: LoopbackProxy?
    @ObservationIgnored
    private var stateTask: Task<Void, Never>?
    @ObservationIgnored
    private var connectionModeTask: Task<Void, Never>?
    @ObservationIgnored
    private var attemptUpdatesTask: Task<Void, Never>?
    @ObservationIgnored
    private let attemptUpdatesDrainDeadline: Duration

    init(
        appConfig: AppConfig? = nil,
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLRuntime.keychainStore.load() },
        makeSession: @escaping @Sendable (StoredPairing) -> any TunnelSessioning & MuxStreamOpening = CFTunnelTransport.makeProductionSession,
        attemptUpdatesDrainDeadline: Duration = CFTunnelTransport.defaultAttemptUpdatesDrainDeadline
    ) {
        self.appConfig = appConfig
        self.loadPairing = loadPairing
        self.makeSession = makeSession
        self.attemptUpdatesDrainDeadline = attemptUpdatesDrainDeadline
    }

    public func connect(
        candidates: [TransportEndpoint],
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) async throws -> Int {
        self.sessionEpoch &+= 1
        let epoch = self.sessionEpoch
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
        observeAttemptUpdates(session, onStageChange: onStageChange)

        do {
            let port = try await raceStartupAgainstConnectWindow(
                session: session,
                candidates: candidates,
                onStageChange: onStageChange,
                connectWindow: connectWindow,
                epoch: epoch
            )
            await connectWindow.close()
            try self.checkCurrent(epoch)
            return port
        } catch {
            await connectWindow.close()
            await session.disconnect()
            throw error
        }
    }

    private func checkCurrent(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard self.sessionEpoch == epoch else { throw CancellationError() }
    }

    private func raceStartupAgainstConnectWindow(
        session: any TunnelSessioning & MuxStreamOpening,
        candidates: [TransportEndpoint],
        onStageChange: @Sendable @escaping (TransportStage) -> Void,
        connectWindow: ConnectWindowTerminalSignal,
        epoch: UInt64
    ) async throws -> Int {
        let startupTask = Task { @MainActor in
            try await self.startSessionAndProxy(
                session: session,
                candidates: candidates,
                onStageChange: onStageChange,
                epoch: epoch
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
        onStageChange: @Sendable @escaping (TransportStage) -> Void,
        epoch: UInt64
    ) async throws -> Int {
        try self.checkCurrent(epoch)
        onStageChange(.racing)
        _ = try await session.connect(endpoints: candidates)
        try self.checkCurrent(epoch)
        await self.drainAttemptUpdates()
        try self.checkCurrent(epoch)
        let mode = await session.connectionMode
        try self.checkCurrent(epoch)
        self.connectionMode = mode
        onStageChange(.tlsHandshaking)
        onStageChange(.muxReady)

        let proxy = LoopbackProxy(opener: session)
        let port: Int
        do {
            port = Int(try await proxy.start())
            try self.checkCurrent(epoch)
        } catch {
            await proxy.stop()
            throw error
        }
        self.proxy = proxy
        let nextGeneration = self.generationSnapshot.currentGeneration + 1
        self.generationSnapshot = TransportGenerationSnapshot(
            currentGeneration: nextGeneration,
            activeGeneration: nextGeneration,
            lastClosedGeneration: self.generationSnapshot.lastClosedGeneration
        )
        onStageChange(.loopbackReady(port: port))
        return port
    }

    public func disconnect() async {
        self.sessionEpoch &+= 1
        let closingGeneration = self.generationSnapshot.activeGeneration
        let closingProxy = self.proxy
        let closingSession = self.session
        let closingUpdates = self.attemptUpdatesTask
        self.stateTask?.cancel()
        self.stateTask = nil
        self.connectionModeTask?.cancel()
        self.connectionModeTask = nil
        self.attemptUpdatesTask = nil
        self.proxy = nil
        self.session = nil
        self.connectionMode = nil
        if let closingGeneration {
            self.generationSnapshot = TransportGenerationSnapshot(
                currentGeneration: self.generationSnapshot.currentGeneration,
                activeGeneration: nil,
                lastClosedGeneration: closingGeneration
            )
        }
        await closingProxy?.stop()
        await closingSession?.disconnect()
        await self.drainAttemptUpdates(task: closingUpdates)
    }

    private func observe(
        session: any TunnelSessioning,
        onDisconnect: @Sendable @escaping (Error?) -> Void,
        onStageChange: @Sendable @escaping (TransportStage) -> Void,
        connectWindow: ConnectWindowTerminalSignal? = nil
    ) {
        stateTask?.cancel()
        let epoch = self.sessionEpoch
        stateTask = Task { @MainActor in
            for await state in session.stateUpdates {
                guard !Task.isCancelled, self.sessionEpoch == epoch else { return }
                if let connectWindow, await connectWindow.observe(state) {
                    continue
                }
                guard !Task.isCancelled, self.sessionEpoch == epoch else { return }
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
        let epoch = self.sessionEpoch
        connectionModeTask = Task { @MainActor [weak self] in
            for await mode in updates {
                guard let self, !Task.isCancelled, self.sessionEpoch == epoch else { return }
                self.connectionMode = mode
            }
        }
    }

    private func observeAttemptUpdates(
        _ session: any TunnelSessioning,
        onStageChange: @Sendable @escaping (TransportStage) -> Void
    ) {
        guard let observing = session as? any TunnelAttemptObserving else {
            onStageChange(.attemptUpdatesUnavailable)
            return
        }
        attemptUpdatesTask?.cancel()
        let epoch = self.sessionEpoch
        attemptUpdatesTask = Task { @MainActor in
            for await event in observing.attemptUpdates {
                guard !Task.isCancelled, self.sessionEpoch == epoch else { return }
                onStageChange(.attemptEvent(event))
            }
            guard self.sessionEpoch == epoch else { return }
            if Task.isCancelled {
                onStageChange(.attemptUpdatesUnavailable)
            } else {
                onStageChange(.attemptUpdatesFinished)
            }
        }
    }

    private func drainAttemptUpdates() async {
        await self.drainAttemptUpdates(task: self.attemptUpdatesTask)
    }

    private func drainAttemptUpdates(task: Task<Void, Never>?) async {
        guard let task else { return }
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask { [attemptUpdatesDrainDeadline] in
                do {
                    try await Task.sleep(for: attemptUpdatesDrainDeadline)
                    return false
                } catch {
                    return true
                }
            }
            let result = await group.next() ?? true
            if !result {
                task.cancel()
            }
            group.cancelAll()
            await group.waitForAll()
        }
    }

    nonisolated private static func makeProductionSession(
        pairing: StoredPairing
    ) -> any TunnelSessioning & MuxStreamOpening {
        let session = TunnelSession(
            pairing: pairing,
            clientInfo: SPLRuntime.clientInfo,
            policy: SessionPolicy(
                keepalive: KeepalivePolicy(
                    interval: .milliseconds(500),
                    missedLimit: 3,
                    // why: false is KeepalivePolicy's default; macOS is the deviator. iOS runs no mux work while
                    // suspended, so relay keepalive would not have caught the reported case. Foreground validation
                    // is the fix, and its 3s probe timeout bounds a dead-mux hang on resume.
                    runsOnRelayPath: false
                )
            )
        )
        // Keep the runtime existential narrow while making an SDK conformance change a compile error.
        let _: any TunnelAttemptObserving = session
        return session
    }
}
