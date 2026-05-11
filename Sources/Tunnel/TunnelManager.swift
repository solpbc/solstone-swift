// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "tunnel")

@Observable
final class TunnelManager {
    var state: TunnelState = .disconnected
    @ObservationIgnored private let transport: any Transporting
    @ObservationIgnored private let endpointCache: EndpointCache
    @ObservationIgnored private let pathMonitor: PathMonitor
    @ObservationIgnored private let loadPairing: @Sendable () throws -> StoredPairing?
    @ObservationIgnored private let deletePairing: @Sendable () throws -> Void
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval
    @ObservationIgnored private let initialRetryDelay: TimeInterval
    @ObservationIgnored private let jitterRange: ClosedRange<Double>
    var reconnectCountdown: Int?
    var consecutiveWiFiFailures: Int = 0
    var isNetworkSatisfied: Bool?
    var currentInterfaceIsWiFi: Bool?
    var lastProbeAlive: Bool?
    var consecutiveKeepaliveFailures: Int = 0
    var reconnectCount: Int = 0
    var connectionStages: [ConnectionStage] = []
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?

    init(
        transport: (any Transporting)? = nil,
        endpointCache: EndpointCache = EndpointCache(),
        pathMonitor: PathMonitor = PathMonitor(),
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLKeychain.load() },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLKeychain.delete() },
        initialRetryDelay: TimeInterval = 2.0,
        jitterRange: ClosedRange<Double> = 0.75...1.25,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.transport = transport ?? CFTunnelTransport()
        self.endpointCache = endpointCache
        self.pathMonitor = pathMonitor
        self.loadPairing = loadPairing
        self.deletePairing = deletePairing
        self.initialRetryDelay = initialRetryDelay
        self.retryDelay = initialRetryDelay
        self.jitterRange = jitterRange
        self.diagnosticLog = diagnosticLog
    }

    var connectionHealth: ConnectionHealth {
        switch self.state {
        case .connected:
            return self.lastProbeAlive == false ? .degraded : .healthy
        default:
            return .unknown
        }
    }

    private func appendStage(_ kind: ConnectionStageKind, detail: String? = nil) {
        let stage = ConnectionStage(id: kind, status: .active, detail: detail, startTime: .now)
        self.connectionStages.append(stage)
        self.diagnosticLog?.append(category: .tunnel, message: "stage: \(kind.rawValue) started\(detail.map { " (\($0))" } ?? "")")
    }

    private func completeStage(_ kind: ConnectionStageKind, detail: String? = nil) {
        guard let index = self.connectionStages.firstIndex(where: { $0.kind == kind }) else { return }
        self.connectionStages[index].status = .done
        if let start = self.connectionStages[index].startTime {
            self.connectionStages[index].duration = Double((ContinuousClock.now - start) / .seconds(1))
        }
        if let detail {
            self.connectionStages[index].detail = detail
        }
        self.diagnosticLog?.append(
            category: .tunnel,
            message: "stage: \(kind.rawValue) done\(self.connectionStages[index].duration.map { String(format: " (%.1fs)", $0) } ?? "")"
        )
    }

    private func failActiveStage() {
        guard let index = self.connectionStages.lastIndex(where: { $0.status == .active }) else { return }
        self.connectionStages[index].status = .failed
        if let start = self.connectionStages[index].startTime {
            self.connectionStages[index].duration = Double((ContinuousClock.now - start) / .seconds(1))
        }
        self.diagnosticLog?.append(
            category: .tunnel,
            severity: .warning,
            message: "stage: \(self.connectionStages[index].kind.rawValue) failed"
        )
    }

    func connect() async {
        if self.connectTask != nil {
            log.info("[solstone-swift] connect() skipped — already in progress")
            return
        }
        switch self.state {
        case .connecting, .connected:
            log.info("[solstone-swift] connect() skipped — already \(self.state)")
            return
        case .disconnected, .error:
            break
        }

        log.info("[solstone-swift] connect() starting")
        if case .error = self.state {
            self.reconnectCount += 1
        }
        self.state = .connecting(.lan)
        self.diagnosticLog?.append(category: .tunnel, message: "connecting")
        self.connectionStages = []

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.connectTask = nil }
            do {
                self.appendStage(.prepareCandidates)
                let candidates = try await self.candidateList()
                self.completeStage(.prepareCandidates, detail: "\(candidates.count) candidate\(candidates.count == 1 ? "" : "s")")

                let localPort = try await self.transport.connect(
                    candidates: candidates,
                    onDisconnect: { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self, case .connected = self.state else { return }
                            log.error("[solstone-swift] SPL tunnel closed unexpectedly")
                            self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "tunnel closed unexpectedly")
                            let tunnelError = error.map { self.mapTransportError($0) } ?? .muxTeardown
                            self.state = .error(tunnelError)
                            await self.transport.disconnect()
                            self.scheduleReconnect(for: tunnelError)
                        }
                    },
                    onStageChange: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.handleStageChange(event)
                        }
                    }
                )

                if Task.isCancelled {
                    await self.transport.disconnect()
                    return
                }

                await Task.yield()
                let endpoint = self.endpoint(for: self.transport.connectionMode)
                self.state = .connected(localPort: localPort, via: endpoint)
                self.completeStage(.loopback, detail: "port \(localPort)")
                self.appendStage(.connected)
                self.completeStage(.connected)
                self.consecutiveWiFiFailures = 0
                self.lastProbeAlive = nil
                self.consecutiveKeepaliveFailures = 0
                log.info("[solstone-swift] connected on localhost:\(localPort) via \(endpoint == .lan ? "lan" : "remote")")
                self.diagnosticLog?.append(
                    category: .tunnel,
                    message: "connected via \(endpoint == .lan ? "local network" : "remote server") on port \(localPort)"
                )
                self.retryDelay = self.initialRetryDelay
                self.cancelReconnect()
                Task {
                    try? await self.endpointCache.refresh(viaLoopbackPort: localPort)
                }
            } catch is CancellationError {
                return
            } catch {
                log.error("[solstone-swift] connect() failed: \(String(describing: error), privacy: .public)")
                await self.transport.disconnect()
                await Task.yield()
                let tunnelError = self.mapTransportError(error)
                self.failActiveStage()
                self.state = .error(tunnelError)
                self.diagnosticLog?.append(
                    category: .tunnel,
                    severity: .error,
                    message: "connection failed",
                    detail: tunnelError.userMessage
                )
                if tunnelError == .revoked {
                    try? self.deletePairing()
                    await self.endpointCache.wipe()
                }
                self.scheduleReconnect(for: tunnelError)
            }
        }
        self.connectTask = task
        await task.value
    }

    func disconnect() async {
        self.cancelReconnect()
        self.state = .disconnected
        self.consecutiveWiFiFailures = 0
        self.lastProbeAlive = nil
        self.consecutiveKeepaliveFailures = 0
        self.reconnectCount = 0
        self.connectionStages = []
        self.connectTask?.cancel()
        self.connectTask = nil
        await self.transport.disconnect()
        self.diagnosticLog?.append(category: .tunnel, message: "disconnected")
    }

    func cancelConnect() {
        self.connectTask?.cancel()
        self.connectTask = nil
        if case .connecting = self.state {
            self.state = .disconnected
        }
    }

    func retryNow() async {
        self.cancelReconnect()
        self.retryDelay = self.initialRetryDelay
        await self.connect()
    }

    // Integration tests use this to bypass real tunnel startup.
    func forceConnected(port: Int, via: ConnectionEndpoint) { self.state = .connected(localPort: port, via: via) }

    func forceDisconnectedForUITest() {
        self.state = .disconnected
    }

    func forceNetworkStatus(isSatisfied: Bool, isWiFi: Bool) {
        self.isNetworkSatisfied = isSatisfied
        self.currentInterfaceIsWiFi = isWiFi
    }

    func handleTunnelFailure() async {
        guard case .connected = self.state else { return }
        log.error("[solstone-swift] tunnel failure detected by portal")
        self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "tunnel failure detected by portal")
        self.state = .error(.muxTeardown)
        await self.transport.disconnect()
        guard case .error(.muxTeardown) = self.state else { return }
        self.scheduleReconnect(for: .muxTeardown)
    }

    func cancelReconnect() {
        self.retryTask?.cancel()
        self.retryTask = nil
        self.reconnectCountdown = nil
    }

    func startNetworkMonitoring() {
        self.pathMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.diagnosticLog?.append(category: .network, message: "path changed")
                switch self.state {
                case .connected:
                    log.info("[solstone-swift] network: reconnecting after path change")
                    await self.transport.disconnect()
                    self.state = .error(.muxTeardown)
                    await self.retryNow()
                case .error(let error) where error.isRetryable:
                    await self.retryNow()
                case .disconnected, .connecting, .error:
                    break
                }
            }
        }
    }

    func stopNetworkMonitoring() {
        self.pathMonitor.stop()
        self.isNetworkSatisfied = nil
        self.currentInterfaceIsWiFi = nil
    }

    func probeConnection() async -> (alive: Bool, latency: Duration)? {
        guard case .connected = self.state else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        let elapsed = clock.now - start
        self.lastProbeAlive = true
        self.diagnosticLog?.append(
            category: .tunnel,
            message: "manual probe alive",
            detail: "latency: \(elapsed)"
        )
        return (true, elapsed)
    }

    private func scheduleReconnect(for error: TunnelError) {
        guard error.isRetryable, self.isNetworkSatisfied != false else { return }
        self.cancelReconnect()
        let jittered = self.retryDelay * Double.random(in: self.jitterRange)
        let delay = max(Int(jittered), 1)
        log.info("[solstone-swift] scheduling reconnect in \(delay)s for \(String(describing: error), privacy: .public)")
        self.reconnectCountdown = delay
        self.retryTask = Task { [weak self] in
            for remaining in stride(from: delay, through: 1, by: -1) {
                guard let self else { return }
                self.reconnectCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.reconnectCountdown = nil
            self.retryDelay = min(self.retryDelay * 2, 60)
            await self.connect()
        }
    }

    private func candidateList() async throws -> [TransportEndpoint] {
        guard let pairing = try self.loadPairing() else {
            throw TunnelError.revoked
        }

        var candidates = await self.endpointCache.endpoints()
        let relay = try TransportEndpoint.candidates(for: pairing).filter { endpoint in
            if case .relay = endpoint {
                return true
            }
            return false
        }
        candidates.append(contentsOf: relay)
        if candidates.isEmpty {
            candidates = try TransportEndpoint.candidates(for: pairing)
        }
        if candidates.isEmpty {
            throw TunnelError.unreachable
        }
        return candidates
    }

    private func handleStageChange(_ event: TransportStage) {
        switch event {
        case .preparingCandidates:
            break
        case .racing:
            self.completeStage(.prepareCandidates)
            self.appendStage(.raceCandidates)
        case .tlsHandshaking:
            self.completeStage(.raceCandidates)
            self.appendStage(.tlsHandshake)
        case .muxReady:
            self.completeStage(.tlsHandshake)
            self.appendStage(.muxReady)
            self.completeStage(.muxReady)
        case .loopbackReady(let port):
            self.appendStage(.loopback)
            self.diagnosticLog?.append(category: .tunnel, message: "loopback ready on port \(port)")
        case .failed(let message):
            self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "transport failed", detail: message)
        }
    }

    private func endpoint(for mode: ConnectionMode?) -> ConnectionEndpoint {
        switch mode {
        case .plDirect:
            return .lan
        case .plViaSpl, nil:
            return .remote
        }
    }

    private func mapTransportError(_ error: Error) -> TunnelError {
        if let tunnelError = error as? TunnelError {
            return tunnelError
        }
        if let cfError = error as? CFTunnelTransportError, cfError == .missingPairing {
            return .revoked
        }
        if let sessionError = error as? SessionError {
            switch sessionError {
            case .unreachable, .invalidRelayURL, .transportFailed:
                return .unreachable
            case .tlsFailed:
                return .tlsHandshakeFailed
            case .directKeepaliveMissed, .notConnected:
                return .muxTeardown
            }
        }
        return .unknown(String(describing: error))
    }
}
