// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "tunnel")
private let waitingRedialDelaySeconds = 60
private let notEntitledAutoReconnectLimit = 3

private enum PathInterfaceBucket: String, Sendable {
    case wifi
    case cellular
    case other
}

private struct PathMeaningfulSignature: Equatable, Sendable {
    let interface: PathInterfaceBucket
    let isSatisfied: Bool
}

#if DEBUG && targetEnvironment(simulator)
struct IntegrationGateCandidateBuildSummary: Sendable, Equatable {
    let originalLocalEndpointCount: Int
    let cachedDirectCandidateCount: Int
    let bootstrapDirectCandidateCount: Int
    let returnedDirectCandidateCount: Int
    let returnedRelayCandidateCount: Int
    let postConnectCachedDirectCandidateCount: Int?

    func withPostConnectCachedDirectCandidateCount(_ count: Int) -> IntegrationGateCandidateBuildSummary {
        IntegrationGateCandidateBuildSummary(
            originalLocalEndpointCount: originalLocalEndpointCount,
            cachedDirectCandidateCount: cachedDirectCandidateCount,
            bootstrapDirectCandidateCount: bootstrapDirectCandidateCount,
            returnedDirectCandidateCount: returnedDirectCandidateCount,
            returnedRelayCandidateCount: returnedRelayCandidateCount,
            postConnectCachedDirectCandidateCount: count
        )
    }
}

private struct IntegrationGateRelayOnlyCandidatePolicy: Sendable {
    func bootstrapPairing(from pairing: StoredPairing) -> StoredPairing {
        StoredPairing(
            instanceID: pairing.instanceID,
            homeLabel: pairing.homeLabel,
            relayEndpoint: pairing.relayEndpoint,
            fingerprint: pairing.fingerprint,
            clientCertPEM: pairing.clientCertPEM,
            clientKeyPEM: pairing.clientKeyPEM,
            caChainPEM: pairing.caChainPEM,
            relayEnrollment: pairing.relayEnrollment,
            localEndpoints: [],
            pairedAt: pairing.pairedAt
        )
    }

    func filterCachedCandidates(_ candidates: [TransportEndpoint]) -> [TransportEndpoint] {
        candidates.filter { endpoint in
            if case .lan = endpoint {
                return false
            }
            return true
        }
    }
}
#endif

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
    @ObservationIgnored private let activeLocalTransferCountProvider: @Sendable @MainActor () -> Int
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var connectWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var waitingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var livenessProbeTask: Task<Void, Never>?
    @ObservationIgnored private let connectDeadline: Duration
    @ObservationIgnored private let waitingDeadline: Duration
    @ObservationIgnored private var probeWatchdog: ProbeWatchdog
    @ObservationIgnored private var reconnectBackoff: ReconnectBackoff
    @ObservationIgnored private let healthyProbeInterval: Duration
    @ObservationIgnored private var consecutiveNotEntitled = 0
    @ObservationIgnored private(set) var lastScheduledReconnectDelay: Duration?
    var reconnectCountdown: Int?
    var currentPathStatus: NetworkPathStatus?
    var isNetworkSatisfied: Bool?
    var currentInterfaceIsWiFi: Bool?
    var lastProbeAlive: Bool?
    @ObservationIgnored private var lastEmittedPathSignature: PathMeaningfulSignature?
    @ObservationIgnored private var redriveBaselineSignature: PathMeaningfulSignature?
    var consecutiveKeepaliveFailures: Int = 0
    var reconnectCount: Int = 0
    var reconnectReasonCounts: [ReconnectReasonBucket: Int] = [:]
    var inboundClosedFaultCounts: [String: Int] = [:]
    @ObservationIgnored private var connectionStages: [ConnectionStage] = []
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var ownerConnectSuccessBannerArmed = false
    @ObservationIgnored private var pendingReconnectReason: ReconnectReasonBucket?
    @ObservationIgnored private(set) var connectionEpoch: UInt64 = 0
#if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private var integrationGateRelayOnlyCandidatePolicy: IntegrationGateRelayOnlyCandidatePolicy?
    @ObservationIgnored private(set) var integrationGateCandidateBuildSummary: IntegrationGateCandidateBuildSummary?
    @ObservationIgnored private(set) var integrationGateLastTransportStage: TransportStage?
    @ObservationIgnored private(set) var integrationGateLastReconnectReasonBucket: ReconnectReasonBucket?
#endif

    init(
        transport: (any Transporting)? = nil,
        endpointCache: EndpointCache = EndpointCache(),
        pathMonitor: PathMonitor = PathMonitor(),
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLRuntime.keychainStore.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLRuntime.keychainStore.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLRuntime.keychainStore.delete() },
        deviceTokenRefresher: DeviceTokenRefresher = DeviceTokenRefresher(clientInfo: SPLRuntime.clientInfo),
        connectDeadline: Duration = .seconds(15),
        waitingDeadline: Duration = .seconds(600),
        probeSession: URLSession = .shared,
        probeURLBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            URL(string: "http://127.0.0.1:\(localPort)/app/network/api/status")
        },
        probeWatchdogPolicy: ProbeWatchdogPolicy = ProbeWatchdogPolicy(
            healthyInterval: .seconds(15),
            // why: inbound bytes prove tunnel liveness; a failed probe more likely indicts the probe path than the tunnel.
            // iOS runs silent=2 / activeInbound=6 deliberately because stronger liveness evidence warrants the higher bar.
            silentFailureLimit: 2,
            activeInboundFailureLimit: 6
        ),
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
        activeLocalTransferCountProvider: @escaping @Sendable @MainActor () -> Int = { 0 },
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
        self.activeLocalTransferCountProvider = activeLocalTransferCountProvider
        self.connectDeadline = connectDeadline
        self.waitingDeadline = waitingDeadline
        self.healthyProbeInterval = probeWatchdogPolicy.healthyInterval
        self.probeWatchdog = ProbeWatchdog(policy: probeWatchdogPolicy, random: random)
        // why: spl-swift prescribes the reconnect table; the app only schedules the chosen step.
        self.reconnectBackoff = ReconnectBackoff(schedule: .default, random: random)
        self.diagnosticLog = diagnosticLog
    }

    var activeConnection: (port: Int, epoch: UInt64)? {
        guard case .connected(let port, _) = self.state else { return nil }
        return (port, self.connectionEpoch)
    }

    var transportGenerationSnapshot: TransportGenerationSnapshot {
        self.transport.generationSnapshot
    }

#if DEBUG && targetEnvironment(simulator)
    func installIntegrationGateRelayOnlyCandidatePolicy() {
        self.integrationGateRelayOnlyCandidatePolicy = IntegrationGateRelayOnlyCandidatePolicy()
        self.integrationGateCandidateBuildSummary = nil
    }

    func clearIntegrationGateRelayOnlyCandidatePolicy() {
        self.integrationGateRelayOnlyCandidatePolicy = nil
        self.integrationGateCandidateBuildSummary = nil
    }

    var integrationGateActiveProductionUploadCount: Int {
        self.activeLocalTransferCountProvider()
    }
#endif

    func revalidateConnectedTunnelForForeground() async -> Bool {
        guard let entry = self.activeConnection else { return false }
        guard let result = await self.probeConnection() else { return false }
        guard self.activeConnection?.epoch == entry.epoch else { return false }
        guard result.alive else {
            await self.forceReconnect(reason: .probeFailed)
            return false
        }
        return true
    }

    private func appendStage(_ kind: ConnectionStageKind, detail: String? = nil) {
        let stage = ConnectionStage(id: kind, status: .active, startTime: .now)
        self.connectionStages.append(stage)
        self.diagnosticLog?.append(category: .tunnel, message: "stage: \(kind.rawValue) started\(detail.map { " (\($0))" } ?? "")")
    }

    private func completeStage(_ kind: ConnectionStageKind, detail: String? = nil) {
        guard let index = self.connectionStages.firstIndex(where: { $0.kind == kind }) else { return }
        self.connectionStages[index].status = .done
        if let start = self.connectionStages[index].startTime {
            self.connectionStages[index].duration = Double((ContinuousClock.now - start) / .seconds(1))
        }
        let durationSegment = self.connectionStages[index].duration.map { String(format: " (%.1fs)", $0) } ?? ""
        self.diagnosticLog?.append(
            category: .tunnel,
            message: "stage: \(kind.rawValue) done\(durationSegment)\(detail.map { " (\($0))" } ?? "")"
        )
    }

    nonisolated static func candidateCountDetail(_ count: Int) -> String {
        "\(count) candidate\(count == 1 ? "" : "s")"
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
#if DEBUG && targetEnvironment(simulator)
            self.integrationGateLastReconnectReasonBucket = bucket
#endif
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
                self.connectionEpoch += 1
                let epoch = self.connectionEpoch
                self.state = .connected(localPort: localPort, via: endpoint)
                self.completeStage(.loopback)
                self.appendStage(.connected)
                self.completeStage(.connected)
                self.lastProbeAlive = nil
                self.consecutiveKeepaliveFailures = 0
                self.consecutiveNotEntitled = 0
                self.probeWatchdog.noteConnectionEstablished()
                self.startLivenessProbe()
                log.info("[solstone-swift] connected on localhost:\(localPort) via \(endpoint == .lan ? "lan" : "remote")")
                self.diagnosticLog?.append(
                    category: .tunnel,
                    message: "connected via \(endpoint == .lan ? "local network" : "remote journal") on port \(localPort)",
                    detail: self.connectionIdentityDetail(port: localPort, epoch: epoch)
                )
                if self.ownerConnectSuccessBannerArmed {
                    self.ownerConnectSuccessBannerArmed = false
                    self.diagnosticLog?.append(category: .tunnel, message: "journal connected")
                }
                self.reconnectBackoff.reset()
                self.cancelReconnect()
                Task {
#if DEBUG && targetEnvironment(simulator)
                    if self.integrationGateRelayOnlyCandidatePolicy != nil {
                        let cachedDirectCount = await self.endpointCache.endpoints()
                            .filter { self.directCandidateKey(for: $0) != nil }
                            .count
                        self.integrationGateCandidateBuildSummary = self.integrationGateCandidateBuildSummary?
                            .withPostConnectCachedDirectCandidateCount(cachedDirectCount)
                        return
                    }
#endif
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
#if DEBUG && targetEnvironment(simulator)
                    if self.integrationGateRelayOnlyCandidatePolicy == nil {
                        try? self.deletePairing()
                        await self.endpointCache.wipe()
                    }
#else
                    try? self.deletePairing()
                    await self.endpointCache.wipe()
#endif
                }
                if self.shouldScheduleReconnect(after: error) {
                    self.pendingReconnectReason = .connectFailed
#if DEBUG && targetEnvironment(simulator)
                    self.integrationGateLastReconnectReasonBucket = .connectFailed
#endif
                    self.scheduleReconnect(for: tunnelError)
                }
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
        var didAuthRefresh = false
        var retryPairing: StoredPairing?
        while true {
            do {
                return try await self.connectTransportOnce(pairingOverride: retryPairing)
            } catch let error as SessionError where error == .authRefreshRequired || error == .revoked {
                guard !didAuthRefresh else {
                    // why: a repeat auth challenge after one refresh is retryable unless the refresher confirms revocation.
                    throw SessionError.unreachable
                }
                didAuthRefresh = true
                await self.transport.disconnect()
                switch await self.refreshAfterAuthChallenge() {
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
        self.completeStage(.prepareCandidates, detail: Self.candidateCountDetail(candidates.count))

        return try await self.transport.connect(
            candidates: candidates,
            onDisconnect: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .inboundClosed(let fault) = (error as? SessionError) {
                        self.inboundClosedFaultCounts[fault ?? "<unspecified>", default: 0] += 1
                    }
                    if let sessionError = error as? SessionError,
                       sessionError == .directKeepaliveMissed || sessionError == .relayKeepaliveMissed {
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

    private func refreshAfterAuthChallenge() async -> ReactiveTokenRefreshDecision {
        let pairing: StoredPairing
        do {
            guard let loaded = try self.loadPairing() else {
                return .revoked
            }
            pairing = loaded
        } catch {
            log.error("[solstone-swift] auth refresh load pairing failed: \(String(describing: error), privacy: .public)")
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

    func disconnect() async {
        let active = self.activeConnection
        self.cancelReconnect()
        self.cancelConnectWatchdog()
        self.cancelWaitingTimeout()
        self.stopLivenessProbe()
        self.state = .disconnected
        self.lastProbeAlive = nil
        self.consecutiveKeepaliveFailures = 0
        self.consecutiveNotEntitled = 0
        self.reconnectCount = 0
        self.reconnectReasonCounts = [:]
        self.pendingReconnectReason = nil
#if DEBUG && targetEnvironment(simulator)
        self.integrationGateLastReconnectReasonBucket = nil
        self.integrationGateLastTransportStage = nil
#endif
        self.connectionStages = []
        self.connectTask?.cancel()
        self.connectTask = nil
        await self.transport.disconnect()
        self.diagnosticLog?.append(
            category: .tunnel,
            message: "disconnected",
            detail: self.connectionIdentityDetail(port: active?.port, epoch: active?.epoch)
        )
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
        self.reconnectBackoff.reset()
        self.consecutiveNotEntitled = 0
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
        self.consecutiveNotEntitled = 0

        await self.connect()
    }

    func armOwnerConnectSuccessBanner() {
        self.ownerConnectSuccessBannerArmed = true
    }

#if DEBUG
    var ownerConnectSuccessBannerArmedForTesting: Bool {
        self.ownerConnectSuccessBannerArmed
    }

    // Integration tests use this to bypass real tunnel startup.
    func forceConnected(port: Int, via: ConnectionEndpoint) {
        self.connectionEpoch += 1
        self.state = .connected(localPort: port, via: via)
    }

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
        let healthyProbeInterval = self.healthyProbeInterval
        self.livenessProbeTask = Task { @MainActor [weak self] in
            var nextProbeInterval = healthyProbeInterval
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let interval = nextProbeInterval
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else {
                    return
                }
                guard case .connected = self.state else {
                    return
                }
                let inboundBeforeProbe = await self.transport.inboundActivitySnapshot()
                let result = await self.probeConnection()
                guard let result else {
                    return
                }
                let inboundAfterProbe = await self.transport.inboundActivitySnapshot()
                let inboundAdvanced = inboundAfterProbe > inboundBeforeProbe
                let activeLocalTransfers = self.activeLocalTransferCountProvider()
                let verdict = self.probeWatchdog.evaluate(
                    probeSucceeded: result.alive,
                    inboundAdvanced: inboundAdvanced,
                    activeLocalTransfers: activeLocalTransfers
                )
                nextProbeInterval = verdict.nextInterval

                if verdict.action == .reconnect {
                    if !result.alive, !inboundAdvanced, activeLocalTransfers > 0 {
                        let active = self.activeConnection
                        self.diagnosticLog?.append(
                            category: .tunnel,
                            severity: .warning,
                            message: "probe not reachable during active uploads",
                            detail: "activeUploads=\(activeLocalTransfers) \(self.connectionIdentityDetail(port: active?.port, epoch: active?.epoch))"
                        )
                    }
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

    private func forceReconnect(reason: ReconnectReason) async {
        guard case .connected = self.state else { return }
        let active = self.activeConnection
        self.pendingReconnectReason = reason.bucket
#if DEBUG && targetEnvironment(simulator)
        self.integrationGateLastReconnectReasonBucket = reason.bucket
#endif
        let tunnelError = reason.tunnelError
        log.error("[solstone-swift] forcing reconnect: \(reason.logLabel, privacy: .public)")
        self.diagnosticLog?.append(
            category: .tunnel,
            severity: .warning,
            message: "forcing reconnect",
            detail: "\(reason.logLabel) \(self.connectionIdentityDetail(port: active?.port, epoch: active?.epoch))"
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
                        self.consecutiveNotEntitled = 0
                        self.pendingReconnectReason = .pathRestore
#if DEBUG && targetEnvironment(simulator)
                        self.integrationGateLastReconnectReasonBucket = .pathRestore
#endif
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
        let active = self.activeConnection
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
        self.diagnosticLog?.append(
            category: .tunnel,
            message: alive ? "probe available" : "probe not reachable",
            detail: "latency: \(elapsed); \(detail); \(self.connectionIdentityDetail(port: active?.port ?? localPort, epoch: active?.epoch))"
        )
        return (alive, elapsed)
    }

    private func connectionIdentityDetail(port: Int?, epoch: UInt64?) -> String {
        "port=\(port.map(String.init) ?? "none") epoch=\(epoch.map(String.init) ?? "none")"
    }

    private func scheduleReconnect(for error: TunnelError) {
        guard error.isRetryable, self.isNetworkSatisfied != false else { return }
        self.cancelReconnect()
        let step = self.reconnectBackoff.nextDelay()
        self.lastScheduledReconnectDelay = step.delay
        let displaySeconds = Self.displaySeconds(for: step.delay)
        let components = step.delay.components
        let wholeSeconds = max(Int(components.seconds), 0)
        let fractional = step.delay - .seconds(components.seconds)
        log.info("[solstone-swift] scheduling reconnect in \(String(describing: step.delay), privacy: .public) for \(String(describing: error), privacy: .public)")
        self.reconnectCountdown = displaySeconds
        self.retryTask = Task { [weak self] in
            if fractional > .zero {
                try? await Task.sleep(for: fractional)
                if Task.isCancelled { return }
            }
            for remaining in stride(from: wholeSeconds, through: 1, by: -1) {
                guard let self else { return }
                self.reconnectCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.reconnectCountdown = nil
            await self.connect()
        }
    }

    private static func displaySeconds(for duration: Duration) -> Int {
        let components = duration.components
        let seconds = Int(components.seconds) + (components.attoseconds > 0 ? 1 : 0)
        return max(seconds, 1)
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

        let bootstrapPairing: StoredPairing
#if DEBUG && targetEnvironment(simulator)
        if let integrationGateRelayOnlyCandidatePolicy {
            bootstrapPairing = integrationGateRelayOnlyCandidatePolicy.bootstrapPairing(from: refreshedPairing)
        } else {
            bootstrapPairing = refreshedPairing
        }
#else
        bootstrapPairing = refreshedPairing
#endif
        let bootstrapCandidates = TransportEndpoint.candidates(for: bootstrapPairing)
        let cachedCandidates = await self.endpointCache.endpoints()
#if DEBUG && targetEnvironment(simulator)
        let effectiveCachedCandidates: [TransportEndpoint]
        if let integrationGateRelayOnlyCandidatePolicy {
            effectiveCachedCandidates = integrationGateRelayOnlyCandidatePolicy.filterCachedCandidates(cachedCandidates)
        } else {
            effectiveCachedCandidates = cachedCandidates
        }
#else
        let effectiveCachedCandidates = cachedCandidates
#endif
        var seenDirects = Set<String>()
        var directCandidates: [TransportEndpoint] = []
        for endpoint in effectiveCachedCandidates + bootstrapCandidates {
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
#if DEBUG && targetEnvironment(simulator)
        if integrationGateRelayOnlyCandidatePolicy != nil {
            self.integrationGateCandidateBuildSummary = IntegrationGateCandidateBuildSummary(
                originalLocalEndpointCount: refreshedPairing.localEndpoints.count,
                cachedDirectCandidateCount: cachedCandidates.filter { self.directCandidateKey(for: $0) != nil }.count,
                bootstrapDirectCandidateCount: bootstrapCandidates.filter { self.directCandidateKey(for: $0) != nil }.count,
                returnedDirectCandidateCount: candidates.filter { self.directCandidateKey(for: $0) != nil }.count,
                returnedRelayCandidateCount: relayCandidates.count,
                postConnectCachedDirectCandidateCount: nil
            )
        }
#endif
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
        guard case .lan(let host, let port, let scope, let unpinnedInterface) = endpoint else {
            return nil
        }
        return "\(host)|\(port)|\(scope)|unpinned=\(unpinnedInterface)"
    }

    private func handleStageChange(_ event: TransportStage) {
#if DEBUG && targetEnvironment(simulator)
        self.integrationGateLastTransportStage = event
#endif
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
            self.appendStage(.loopback, detail: "port \(port)")
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
            case .unreachable, .transportFailed, .inboundClosed, .notEntitled:
                return .unreachable
            case .authRefreshRequired:
                // why: relay/WAF auth challenges are retryable unless token refresh proves revocation.
                return .unreachable
            case .revoked:
                return .revoked
            case .tlsFailed:
                return .tlsHandshakeFailed
            case .directKeepaliveMissed, .relayKeepaliveMissed, .notConnected:
                return .muxTeardown
            }
        }
        return .unknown(String(describing: error))
    }

    private func shouldScheduleReconnect(after error: Error) -> Bool {
        guard let sessionError = error as? SessionError, sessionError == .notEntitled else {
            self.consecutiveNotEntitled = 0
            return true
        }

        self.consecutiveNotEntitled += 1
        guard self.consecutiveNotEntitled < notEntitledAutoReconnectLimit else {
            log.info("[solstone-swift] relay not entitled repeated; stopping automatic reconnect")
            return false
        }
        return true
    }
}
