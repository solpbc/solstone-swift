// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "tunnel")
private let waitingRedialDelaySeconds = 60

private enum PathInterfaceBucket: String, Sendable {
    case wifi
    case cellular
    case other
}

private struct PathMeaningfulSignature: Equatable, Sendable {
    let interface: PathInterfaceBucket
    let isSatisfied: Bool
}

enum RedriveTrigger: Sendable, Equatable {
    case networkChanged
    case foreground

    var label: String {
        switch self {
        case .networkChanged:
            return "network changed"
        case .foreground:
            return "foreground"
        }
    }
}

enum ReconnectReasonBucket: String, CaseIterable, Sendable {
    case transportClosed
    case pathChanged
    case probeFailed
    case keepaliveMissed
    case connectFailed
    case watchdogTimeout
    case pathRestore
    case other

    var exportLabel: String {
        switch self {
        case .transportClosed:
            return "transport closed"
        case .pathChanged:
            return "path changed"
        case .probeFailed:
            return "probe failed"
        case .keepaliveMissed:
            return "keepalive missed"
        case .connectFailed:
            return "connect failed"
        case .watchdogTimeout:
            return "watchdog timeout"
        case .pathRestore:
            return "path restore"
        case .other:
            return "other"
        }
    }
}

private enum ReconnectReason: Sendable, Equatable {
    case transportClosed(TunnelError)
    case pathChanged
    case probeFailed
    case keepaliveMissed

    var tunnelError: TunnelError {
        switch self {
        case .transportClosed(let error):
            return error
        case .pathChanged, .probeFailed, .keepaliveMissed:
            return .muxTeardown
        }
    }

    var bucket: ReconnectReasonBucket {
        switch self {
        case .transportClosed:
            return .transportClosed
        case .pathChanged:
            return .pathChanged
        case .probeFailed:
            return .probeFailed
        case .keepaliveMissed:
            return .keepaliveMissed
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
        case .keepaliveMissed:
            return "keepalive missed"
        }
    }
}

private enum ReactiveTokenRefreshDecision: Sendable {
    case retry(StoredPairing)
    case revoked
    case unreachable
}

@Observable
final class TunnelManager {
    var state: TunnelState = .disconnected
    @ObservationIgnored private let transport: any Transporting
    @ObservationIgnored private let endpointCache: EndpointCache
    @ObservationIgnored private let pathMonitor: PathMonitor
    @ObservationIgnored private let loadPairing: @Sendable () throws -> StoredPairing?
    @ObservationIgnored private let savePairing: @Sendable (StoredPairing) throws -> Void
    @ObservationIgnored private let deletePairing: @Sendable () throws -> Void
    @ObservationIgnored private let deviceTokenRefresher: DeviceTokenRefresher
    @ObservationIgnored private let probeSession: URLSession
    @ObservationIgnored private let probeURLBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var connectWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var waitingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var livenessProbeTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval
    @ObservationIgnored private let initialRetryDelay: TimeInterval
    @ObservationIgnored private let connectDeadline: Duration
    @ObservationIgnored private let waitingDeadline: Duration
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
    @ObservationIgnored private var redriveBaselineSignature: PathMeaningfulSignature?
    var consecutiveKeepaliveFailures: Int = 0
    var reconnectCount: Int = 0
    var reconnectReasonCounts: [ReconnectReasonBucket: Int] = [:]
    var inboundClosedFaultCounts: [String: Int] = [:]
    var connectionStages: [ConnectionStage] = []
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var ownerConnectSuccessBannerArmed = false
    @ObservationIgnored private var pendingReconnectReason: ReconnectReasonBucket?

    init(
        transport: (any Transporting)? = nil,
        endpointCache: EndpointCache = EndpointCache(),
        pathMonitor: PathMonitor = PathMonitor(),
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLKeychain.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLKeychain.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLKeychain.delete() },
        deviceTokenRefresher: DeviceTokenRefresher = DeviceTokenRefresher(),
        initialRetryDelay: TimeInterval = 2.0,
        connectDeadline: Duration = .seconds(15),
        waitingDeadline: Duration = .seconds(600),
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
        self.savePairing = savePairing
        self.deletePairing = deletePairing
        self.deviceTokenRefresher = deviceTokenRefresher
        self.probeSession = probeSession
        self.probeURLBuilder = probeURLBuilder
        self.initialRetryDelay = initialRetryDelay
        self.connectDeadline = connectDeadline
        self.waitingDeadline = waitingDeadline
        self.retryDelay = initialRetryDelay
        self.jitterRange = jitterRange
        self.probeInterval = probeInterval
        self.probeFailureThreshold = probeFailureThreshold
        self.diagnosticLog = diagnosticLog
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
        case .disconnected, .waitingForHome, .error:
            break
        }

        log.info("[solstone-swift] connect() starting")
        if case .error = self.state {
            self.reconnectCount += 1
            let bucket = self.pendingReconnectReason ?? .other
            self.reconnectReasonCounts[bucket, default: 0] += 1
            self.pendingReconnectReason = nil
        }
        self.state = .connecting
        self.diagnosticLog?.append(category: .tunnel, message: "connecting")
        self.connectionStages = []

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.connectTask = nil }
            do {
                let localPort = try await self.connectWithReactiveTokenRefresh()

                if Task.isCancelled {
                    await self.transport.disconnect()
                    return
                }

                self.cancelConnectWatchdog()
                self.cancelWaitingTimeout()
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
                self.cancelWaitingTimeout()
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
                self.pendingReconnectReason = .connectFailed
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
            self.pendingReconnectReason = .watchdogTimeout
            self.scheduleReconnect(for: .unreachable)
        }
        await task.value
    }

    private func connectWithReactiveTokenRefresh() async throws -> Int {
        var didReactiveRefresh = false
        var didHandshakeRefresh = false
        var retryPairing: StoredPairing?
        while true {
            do {
                return try await self.connectTransportOnce(pairingOverride: retryPairing)
            } catch SessionError.tokenExpired {
                guard !didReactiveRefresh else {
                    throw SessionError.revoked
                }
                didReactiveRefresh = true
                await self.transport.disconnect()
                switch await self.refreshAfterTokenExpired() {
                case .retry(let updated):
                    retryPairing = updated
                    continue
                case .revoked:
                    throw SessionError.revoked
                case .unreachable:
                    throw SessionError.unreachable
                }
            } catch SessionError.revoked {
                guard !didHandshakeRefresh else {
                    throw SessionError.unreachable
                }
                didHandshakeRefresh = true
                await self.transport.disconnect()
                switch await self.refreshAfterHandshakeRevoked() {
                case .retry(let updated):
                    retryPairing = updated
                    continue
                case .revoked:
                    throw SessionError.revoked
                case .unreachable:
                    throw SessionError.unreachable
                }
            }
        }
    }

    private func connectTransportOnce(pairingOverride: StoredPairing? = nil) async throws -> Int {
        self.appendStage(.prepareCandidates)
        let candidates = try await self.candidateList(pairingOverride: pairingOverride)
        self.completeStage(.prepareCandidates, detail: "\(candidates.count) candidate\(candidates.count == 1 ? "" : "s")")

        return try await self.transport.connect(
            candidates: candidates,
            onDisconnect: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .inboundClosed(let fault) = (error as? SessionError) {
                        self.inboundClosedFaultCounts[fault ?? "<unspecified>", default: 0] += 1
                    }
                    if let sessionError = error as? SessionError, sessionError == .directKeepaliveMissed {
                        await self.forceReconnect(reason: .keepaliveMissed)
                    } else {
                        await self.forceReconnect(
                            reason: .transportClosed(error.map { self.mapTransportError($0) } ?? .muxTeardown)
                        )
                    }
                }
            },
            onStageChange: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleStageChange(event)
                }
            }
        )
    }

    private func refreshAfterTokenExpired() async -> ReactiveTokenRefreshDecision {
        let pairing: StoredPairing
        do {
            guard let loaded = try self.loadPairing() else {
                return .revoked
            }
            pairing = loaded
        } catch {
            log.error("[solstone-swift] token refresh load pairing failed: \(String(describing: error), privacy: .public)")
            return .unreachable
        }

        switch await self.deviceTokenRefresher.refreshNow(pairing: pairing) {
        case .refreshed(let updated):
            self.persistRefreshedPairing(updated)
            return .retry(updated)
        case .notNeeded:
            // nothing-to-refresh (the reloaded pairing has no relay enrollment) must
            // never destroy the pairing — unreachable, not revoked.
            return .unreachable
        case .transientFailure:
            return .unreachable
        case .definitiveAuthFailure:
            return .revoked
        }
    }

    private func refreshAfterHandshakeRevoked() async -> ReactiveTokenRefreshDecision {
        let pairing: StoredPairing
        do {
            guard let loaded = try self.loadPairing() else {
                return .revoked
            }
            pairing = loaded
        } catch {
            log.error("[solstone-swift] handshake-revoked refresh load pairing failed: \(String(describing: error), privacy: .public)")
            return .unreachable
        }

        switch await self.deviceTokenRefresher.refreshNow(pairing: pairing) {
        case .refreshed(let updated):
            self.persistRefreshedPairing(updated)
            return .retry(updated)
        case .notNeeded:
            return .unreachable
        case .transientFailure:
            return .unreachable
        case .definitiveAuthFailure:
            return .revoked
        }
    }

    func disconnect() async {
        self.cancelReconnect()
        self.cancelConnectWatchdog()
        self.cancelWaitingTimeout()
        self.stopLivenessProbe()
        self.state = .disconnected
        self.consecutiveWiFiFailures = 0
        self.lastProbeAlive = nil
        self.consecutiveProbeFailures = 0
        self.consecutiveKeepaliveFailures = 0
        self.reconnectCount = 0
        self.reconnectReasonCounts = [:]
        self.pendingReconnectReason = nil
        self.connectionStages = []
        self.connectTask?.cancel()
        self.connectTask = nil
        await self.transport.disconnect()
        self.diagnosticLog?.append(category: .tunnel, message: "disconnected")
    }

    func cancelConnect() {
        self.cancelConnectWatchdog()
        self.cancelWaitingTimeout()
        self.stopLivenessProbe()
        self.connectTask?.cancel()
        self.connectTask = nil
        if case .connecting = self.state {
            self.state = .disconnected
        }
        if case .waitingForHome = self.state {
            self.state = .disconnected
        }
    }

    func retryNow() async {
        self.cancelReconnect()
        self.retryDelay = self.initialRetryDelay
        await self.connect()
    }

    func redriveFromWaitingForHome(reason: RedriveTrigger) async {
        guard case .waitingForHome = self.state else { return }

        self.cancelWaitingTimeout()

        let stalled = self.connectTask
        stalled?.cancel()

        await self.transport.disconnect()
        await stalled?.value

        guard case .waitingForHome = self.state else { return }

        self.diagnosticLog?.append(
            category: .tunnel,
            message: "re-dialing",
            detail: reason.label
        )

        await self.connect()
    }

    func armOwnerConnectSuccessBanner() {
        self.ownerConnectSuccessBannerArmed = true
    }

#if DEBUG
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
#endif

    func cancelReconnect() {
        self.retryTask?.cancel()
        self.retryTask = nil
        self.reconnectCountdown = nil
    }

    private func cancelConnectWatchdog() {
        self.connectWatchdogTask?.cancel()
        self.connectWatchdogTask = nil
    }

    private func startWaitingTimeout() {
        self.cancelWaitingTimeout()
        self.waitingTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.waitingDeadline)
            guard !Task.isCancelled else { return }
            guard case .waitingForHome = self.state else { return }
            self.connectTask?.cancel()
            await self.transport.disconnect()
            guard !Task.isCancelled else { return }
            guard case .waitingForHome = self.state else { return }
            self.waitingTimeoutTask = nil
            self.scheduleWaitingRedial()
        }
    }

    private func cancelWaitingTimeout() {
        self.waitingTimeoutTask?.cancel()
        self.waitingTimeoutTask = nil
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
                let inboundBeforeProbe = await self.transport.inboundActivitySnapshot()
                let result = await self.probeConnection()
                if result?.alive == false {
                    let inboundAfterProbe = await self.transport.inboundActivitySnapshot()
                    if inboundAfterProbe > inboundBeforeProbe {
                        self.consecutiveProbeFailures = 0
                        continue
                    }
                    if self.consecutiveProbeFailures >= self.probeFailureThreshold {
                        await self.forceReconnect(reason: .probeFailed)
                        return
                    }
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
        self.pendingReconnectReason = reason.bucket
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
                        self.pendingReconnectReason = .pathRestore
                        self.scheduleReconnect(for: error)
                    }
                case .disconnected:
                    if status.isSatisfied {
                        self.scheduleReconnect(for: .muxTeardown)
                    }
                case .connecting, .error:
                    break
                case .waitingForHome:
                    let baseline = self.redriveBaselineSignature
                    self.redriveBaselineSignature = signature
                    if signature.isSatisfied,
                       baseline?.isSatisfied != true || signature.interface != baseline?.interface {
                        await self.redriveFromWaitingForHome(reason: .networkChanged)
                    }
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

    private func scheduleWaitingRedial() {
        self.cancelReconnect()
        self.reconnectCountdown = waitingRedialDelaySeconds
        self.retryTask = Task { [weak self] in
            for remaining in stride(from: waitingRedialDelaySeconds, through: 1, by: -1) {
                guard let self else { return }
                self.reconnectCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.reconnectCountdown = nil
            guard case .waitingForHome = self.state else { return }
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

    private func candidateList(pairingOverride: StoredPairing? = nil) async throws -> [TransportEndpoint] {
        let pairing: StoredPairing
        if let pairingOverride {
            pairing = pairingOverride
        } else {
            guard let loaded = try self.loadPairing() else {
                throw TunnelError.revoked
            }
            pairing = loaded
        }

        let refreshedPairing: StoredPairing
        if pairingOverride != nil {
            refreshedPairing = pairing
        } else {
            switch await self.deviceTokenRefresher.refreshIfNeeded(pairing: pairing, now: Date()) {
            case .refreshed(let updated):
                self.persistRefreshedPairing(updated)
                refreshedPairing = updated
            case .notNeeded(let current), .transientFailure(let current):
                refreshedPairing = current
            case .definitiveAuthFailure:
                refreshedPairing = pairing
            }
        }

        let bootstrapCandidates = try TransportEndpoint.candidates(for: refreshedPairing)
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

    private func persistRefreshedPairing(_ pairing: StoredPairing) {
        do {
            try self.savePairing(pairing)
        } catch {
            log.error("[solstone-swift] refreshed token save failed: \(String(describing: error), privacy: .public)")
        }
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
        case .awaitingBroker:
            self.completeStage(.raceCandidates)
            self.redriveBaselineSignature = self.currentPathStatus.map(self.pathMeaningfulSignature)
            self.state = .waitingForHome
            self.cancelConnectWatchdog()
            self.startWaitingTimeout()
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
            case .unreachable, .invalidRelayURL, .transportFailed, .inboundClosed:
                return .unreachable
            case .revoked, .tokenExpired:
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
