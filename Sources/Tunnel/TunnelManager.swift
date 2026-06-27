// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "tunnel")

private enum PathInterfaceBucket: String, Sendable {
    case wifi
    case cellular
    case other
}

private struct PathMeaningfulSignature: Equatable, Sendable {
    let interface: PathInterfaceBucket
    let isSatisfied: Bool
}

private enum ReconnectReason: Sendable, Equatable {
    case transportClosed(TunnelError)
    case pathChanged
    case probeFailed

    var tunnelError: TunnelError {
        switch self {
        case .transportClosed(let error):
            return error
        case .pathChanged, .probeFailed:
            return .muxTeardown
        }
    }

    var logLabel: String {
        switch self {
        case .transportClosed:
            return "transport closed"
        case .pathChanged:
            return "path changed"
        case .probeFailed:
            return "probe failed"
        }
    }
}

@Observable
final class TunnelManager {
    var state: TunnelState = .disconnected
    @ObservationIgnored private let transport: any Transporting
    @ObservationIgnored private let endpointCache: EndpointCache
    @ObservationIgnored private let pathMonitor: PathMonitor
    @ObservationIgnored private let loadPairing: @Sendable () throws -> StoredPairing?
    @ObservationIgnored private let deletePairing: @Sendable () throws -> Void
    @ObservationIgnored private let probeSession: URLSession
    @ObservationIgnored private let probeURLBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var connectWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var livenessProbeTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval
    @ObservationIgnored private let initialRetryDelay: TimeInterval
    @ObservationIgnored private let connectDeadline: Duration
    @ObservationIgnored private let jitterRange: ClosedRange<Double>
    @ObservationIgnored private let probeInterval: Duration
    @ObservationIgnored private let probeFailureThreshold: Int
    var reconnectCountdown: Int?
    var consecutiveWiFiFailures: Int = 0
    var currentPathStatus: NetworkPathStatus?
    var isNetworkSatisfied: Bool?
    var currentInterfaceIsWiFi: Bool?
    var lastProbeAlive: Bool?
    @ObservationIgnored private var consecutiveProbeFailures: Int = 0
    @ObservationIgnored private var lastEmittedPathSignature: PathMeaningfulSignature?
    var consecutiveKeepaliveFailures: Int = 0
    var reconnectCount: Int = 0
    var connectionStages: [ConnectionStage] = []
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var ownerConnectSuccessBannerArmed = false

    init(
        transport: (any Transporting)? = nil,
        endpointCache: EndpointCache = EndpointCache(),
        pathMonitor: PathMonitor = PathMonitor(),
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLKeychain.load() },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLKeychain.delete() },
        initialRetryDelay: TimeInterval = 2.0,
        connectDeadline: Duration = .seconds(15),
        jitterRange: ClosedRange<Double> = 0.75...1.25,
        probeSession: URLSession = .shared,
        probeURLBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            URL(string: "http://127.0.0.1:\(localPort)/app/network/api/status")
        },
        probeInterval: Duration = .seconds(15),
        probeFailureThreshold: Int = 2,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.transport = transport ?? CFTunnelTransport()
        self.endpointCache = endpointCache
        self.pathMonitor = pathMonitor
        self.loadPairing = loadPairing
        self.deletePairing = deletePairing
        self.probeSession = probeSession
        self.probeURLBuilder = probeURLBuilder
        self.initialRetryDelay = initialRetryDelay
        self.connectDeadline = connectDeadline
        self.retryDelay = initialRetryDelay
        self.jitterRange = jitterRange
        self.probeInterval = probeInterval
        self.probeFailureThreshold = probeFailureThreshold
        self.diagnosticLog = diagnosticLog
    }

    var connectionHealth: ConnectionHealth {
        switch self.state {
        case .connected:
            return self.consecutiveProbeFailures >= 2 ? .degraded : .healthy
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
        self.state = .connecting
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
                            guard let self else { return }
                            await self.forceReconnect(
                                reason: .transportClosed(error.map { self.mapTransportError($0) } ?? .muxTeardown)
                            )
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

                self.cancelConnectWatchdog()
                await Task.yield()
                let endpoint = self.endpoint(for: self.transport.connectionMode)
                self.state = .connected(localPort: localPort, via: endpoint)
                self.completeStage(.loopback, detail: "port \(localPort)")
                self.appendStage(.connected)
                self.completeStage(.connected)
                self.consecutiveWiFiFailures = 0
                self.lastProbeAlive = nil
                self.consecutiveProbeFailures = 0
                self.consecutiveKeepaliveFailures = 0
                self.startLivenessProbe()
                log.info("[solstone-swift] connected on localhost:\(localPort) via \(endpoint == .lan ? "lan" : "remote")")
                self.diagnosticLog?.append(
                    category: .tunnel,
                    message: "connected via \(endpoint == .lan ? "local network" : "remote journal") on port \(localPort)"
                )
                if self.ownerConnectSuccessBannerArmed {
                    self.ownerConnectSuccessBannerArmed = false
                    self.diagnosticLog?.append(category: .tunnel, message: "journal connected")
                }
                self.retryDelay = self.initialRetryDelay
                self.cancelReconnect()
                Task {
                    try? await self.endpointCache.refresh(viaLoopbackPort: localPort)
                }
            } catch is CancellationError {
                self.cancelConnectWatchdog()
                return
            } catch {
                if Task.isCancelled { return }
                self.cancelConnectWatchdog()
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
        self.connectWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.connectDeadline)
            guard !Task.isCancelled else { return }
            guard case .connecting = self.state else { return }
            self.connectTask?.cancel()
            await self.transport.disconnect()
            guard case .connecting = self.state else { return }
            self.failActiveStage()
            self.state = .error(.unreachable)
            self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "connection timed out", detail: nil)
            self.scheduleReconnect(for: .unreachable)
        }
        await task.value
    }

    func disconnect() async {
        self.cancelReconnect()
        self.cancelConnectWatchdog()
        self.stopLivenessProbe()
        self.state = .disconnected
        self.consecutiveWiFiFailures = 0
        self.lastProbeAlive = nil
        self.consecutiveProbeFailures = 0
        self.consecutiveKeepaliveFailures = 0
        self.reconnectCount = 0
        self.connectionStages = []
        self.connectTask?.cancel()
        self.connectTask = nil
        await self.transport.disconnect()
        self.diagnosticLog?.append(category: .tunnel, message: "disconnected")
    }

    func cancelConnect() {
        self.cancelConnectWatchdog()
        self.stopLivenessProbe()
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

    func armOwnerConnectSuccessBanner() {
        self.ownerConnectSuccessBannerArmed = true
    }

    // Integration tests use this to bypass real tunnel startup.
    func forceConnected(port: Int, via: ConnectionEndpoint) { self.state = .connected(localPort: port, via: via) }

    func forceDisconnectedForUITest() {
        self.state = .disconnected
    }

    func forceNetworkStatus(isSatisfied: Bool, isWiFi: Bool) {
        self.currentPathStatus = NetworkPathStatus(
            isSatisfied: isSatisfied,
            isWiFi: isWiFi,
            isCellular: !isWiFi,
            isExpensive: false,
            isConstrained: false
        )
        self.isNetworkSatisfied = isSatisfied
        self.currentInterfaceIsWiFi = isWiFi
    }

    func cancelReconnect() {
        self.retryTask?.cancel()
        self.retryTask = nil
        self.reconnectCountdown = nil
    }

    private func cancelConnectWatchdog() {
        self.connectWatchdogTask?.cancel()
        self.connectWatchdogTask = nil
    }

    private func startLivenessProbe() {
        self.stopLivenessProbe()
        self.livenessProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.jitteredProbeInterval() else {
                    return
                }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                guard case .connected = self.state else {
                    return
                }
                let result = await self.probeConnection()
                if result?.alive == false,
                   self.consecutiveProbeFailures >= self.probeFailureThreshold {
                    await self.forceReconnect(reason: .probeFailed)
                    return
                }
            }
        }
    }

    private func stopLivenessProbe() {
        self.livenessProbeTask?.cancel()
        self.livenessProbeTask = nil
    }

    private func jitteredProbeInterval() -> Duration {
        let components = self.probeInterval.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let milliseconds = max(Int(seconds * 1_000 * Double.random(in: self.jitterRange)), 1)
        return .milliseconds(milliseconds)
    }

    private func forceReconnect(reason: ReconnectReason) async {
        guard case .connected = self.state else { return }
        let tunnelError = reason.tunnelError
        log.error("[solstone-swift] forcing reconnect: \(reason.logLabel, privacy: .public)")
        self.diagnosticLog?.append(
            category: .tunnel,
            severity: .warning,
            message: "forcing reconnect",
            detail: reason.logLabel
        )
        self.cancelConnectWatchdog()
        self.cancelReconnect()
        self.stopLivenessProbe()
        self.connectTask?.cancel()
        self.connectTask = nil
        self.state = .error(tunnelError)
        await self.transport.disconnect()
        self.scheduleReconnect(for: tunnelError)
    }

    func startNetworkMonitoring() {
        self.pathMonitor.start { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousBucket = self.currentPathStatus.map(self.pathInterfaceBucket)
                self.applyPathStatus(status)
                let detail = self.pathStatusDetail(status)
                log.debug("[solstone-swift] path changed: \(detail, privacy: .public)")
                let signature = self.pathMeaningfulSignature(status)
                if signature != self.lastEmittedPathSignature {
                    self.lastEmittedPathSignature = signature
                    self.diagnosticLog?.append(
                        category: .tunnel,
                        message: "path changed",
                        detail: detail
                    )
                }
                switch self.state {
                case .connected:
                    if status.isSatisfied,
                       let previousBucket,
                       previousBucket != self.pathInterfaceBucket(status) {
                        await self.forceReconnect(reason: .pathChanged)
                    }
                case .error(let error) where error.isRetryable:
                    if status.isSatisfied {
                        self.scheduleReconnect(for: error)
                    }
                case .disconnected:
                    if status.isSatisfied {
                        self.scheduleReconnect(for: .muxTeardown)
                    }
                case .connecting, .error:
                    break
                }
            }
        }
    }

    func stopNetworkMonitoring() {
        self.pathMonitor.stop()
        self.currentPathStatus = nil
        self.isNetworkSatisfied = nil
        self.currentInterfaceIsWiFi = nil
        self.lastEmittedPathSignature = nil
    }

    func probeConnection() async -> (alive: Bool, latency: Duration)? {
        guard case .connected(let localPort, _) = self.state else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        let alive: Bool
        let detail: String
        if let url = self.probeURLBuilder(localPort) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            do {
                let (_, response) = try await self.probeSession.data(for: request)
                if let http = response as? HTTPURLResponse {
                    alive = 200..<300 ~= http.statusCode
                    detail = "endpoint: /app/network/api/status; status: \(http.statusCode)"
                } else {
                    alive = false
                    detail = "endpoint: /app/network/api/status; non-http response"
                }
            } catch {
                alive = false
                detail = "endpoint: /app/network/api/status; error: \(String(describing: error))"
            }
        } else {
            alive = false
            detail = "endpoint unavailable"
        }
        let elapsed = clock.now - start
        self.lastProbeAlive = alive
        if alive {
            self.consecutiveProbeFailures = 0
        } else {
            self.consecutiveProbeFailures += 1
        }
        self.diagnosticLog?.append(
            category: .tunnel,
            message: alive ? "probe available" : "probe not reachable",
            detail: "latency: \(elapsed); \(detail)"
        )
        return (alive, elapsed)
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

    private func applyPathStatus(_ status: NetworkPathStatus) {
        self.currentPathStatus = status
        self.isNetworkSatisfied = status.isSatisfied
        self.currentInterfaceIsWiFi = status.isWiFi
    }

    private func pathStatusDetail(_ status: NetworkPathStatus) -> String {
        let interface = self.pathInterfaceBucket(status).rawValue
        let satisfied = status.isSatisfied ? "satisfied" : "unsatisfied"
        return "\(interface) · \(satisfied) · expensive=\(status.isExpensive) · constrained=\(status.isConstrained)"
    }

    private func pathMeaningfulSignature(_ status: NetworkPathStatus) -> PathMeaningfulSignature {
        PathMeaningfulSignature(
            interface: self.pathInterfaceBucket(status),
            isSatisfied: status.isSatisfied
        )
    }

    private func pathInterfaceBucket(_ status: NetworkPathStatus) -> PathInterfaceBucket {
        if status.isWiFi {
            return .wifi
        }
        if status.isCellular {
            return .cellular
        }
        return .other
    }

    private func candidateList() async throws -> [TransportEndpoint] {
        guard let pairing = try self.loadPairing() else {
            throw TunnelError.revoked
        }

        let bootstrapCandidates = try TransportEndpoint.candidates(for: pairing)
        let cachedCandidates = await self.endpointCache.endpoints()
        var seenDirects = Set<String>()
        var directCandidates: [TransportEndpoint] = []
        for endpoint in cachedCandidates + bootstrapCandidates {
            guard let key = self.directCandidateKey(for: endpoint),
                  seenDirects.insert(key).inserted
            else {
                continue
            }
            directCandidates.append(endpoint)
        }
        let relayCandidates = bootstrapCandidates.filter { endpoint in
            if case .relay = endpoint {
                return true
            }
            return false
        }

        let candidates = directCandidates + relayCandidates
        if candidates.isEmpty {
            throw TunnelError.unreachable
        }
        return candidates
    }

    private func directCandidateKey(for endpoint: TransportEndpoint) -> String? {
        guard case .lan(let host, let port, let scope) = endpoint else {
            return nil
        }
        return "\(host)|\(port)|\(scope)"
    }

    private func handleStageChange(_ event: TransportStage) {
        switch event {
        case .preparingCandidates:
            break
        case .racing:
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
            self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "couldn't reach your journal", detail: message)
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

    func mapTransportError(_ error: Error) -> TunnelError {
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
            case .revoked:
                return .revoked
            case .tlsFailed:
                return .tlsHandshakeFailed
            case .directKeepaliveMissed, .notConnected:
                return .muxTeardown
            }
        }
        return .unknown(String(describing: error))
    }
}
