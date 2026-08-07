// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import Crypto
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "tunnel")
private let brokerWaitCadence = Duration.seconds(30)
private let maximumSnapshotCandidateLines = 6
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
    case cadence
    case manual

    var label: String {
        switch self {
        case .networkChanged:
            return "network changed"
        case .foreground:
            return "foreground"
        case .cadence:
            return "cadence"
        case .manual:
            return "manual"
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

private struct BrokerWaitEpisode: Sendable {
    let startedAt: ContinuousClock.Instant
    var reraceCount: Int
    var nextCadenceDeadline: ContinuousClock.Instant?
    var pausedBecauseInactive: Bool
}

private enum AttemptTelemetryCompleteness: String, Sendable {
    case active
    case complete
    case unavailable
}

private enum UnfinishedAttemptReason: String, Sendable {
    case rerace
    case ended
}

private struct CandidateAttemptTelemetry: Sendable {
    let ordinal: Int
    let route: TunnelAttemptRoute
    let startedAt: ContinuousClock.Instant
    var phase: TunnelAttemptPhase
    var unfinishedReason: UnfinishedAttemptReason?
}

private struct HomeListenerObservation: Sendable {
    let journalFingerprint: String
    let connectionEpoch: UInt64
    let probeSequence: UInt64
    let generation: Int
    let observedAt: ContinuousClock.Instant
}

private struct NetworkStatusPayload: Decodable, Sendable {
    let relayListenGeneration: Int?

    enum CodingKeys: String, CodingKey {
        case relayListenGeneration = "relay_listen_generation"
    }
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
    @ObservationIgnored private var brokerWaitCadenceTask: Task<Void, Never>?
    @ObservationIgnored private var waitingRedriveTask: Task<Void, Never>?
    @ObservationIgnored private var waitingRedriveID: UInt64?
    @ObservationIgnored private var nextWaitingRedriveID: UInt64 = 0
    @ObservationIgnored private var livenessProbeTask: Task<Void, Never>?
    @ObservationIgnored private let connectDeadline: Duration
    @ObservationIgnored private let clock: any TunnelClock
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
    @ObservationIgnored private var nextAttemptEpoch: UInt64 = 0
    @ObservationIgnored private var activeAttemptEpoch: UInt64?
    @ObservationIgnored private var brokerWaitEpisode: BrokerWaitEpisode?
    @ObservationIgnored private var scenePhase: TunnelScenePhase = .inactive
    @ObservationIgnored private var telemetryCompleteness: AttemptTelemetryCompleteness = .unavailable
    @ObservationIgnored private var candidateTelemetry: [Int: CandidateAttemptTelemetry] = [:]
    @ObservationIgnored private var candidateTelemetryTotal = 0
    @ObservationIgnored private var currentTelemetryEpoch: UInt64?
    @ObservationIgnored private var journalFingerprint: String?
    @ObservationIgnored private var latestListenerObservation: HomeListenerObservation?
    @ObservationIgnored private var latestProbeSequence: UInt64 = 0
    @ObservationIgnored private var latestStartedProbeSequenceByEpoch: [UInt64: UInt64] = [:]
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
        clock: any TunnelClock = LiveTunnelClock(),
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
        self.clock = clock
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

    private func beginAttempt() -> UInt64 {
        self.nextAttemptEpoch &+= 1
        self.activeAttemptEpoch = self.nextAttemptEpoch
        self.currentTelemetryEpoch = self.nextAttemptEpoch
        self.candidateTelemetry = [:]
        self.candidateTelemetryTotal = 0
        self.telemetryCompleteness = .unavailable
        return self.nextAttemptEpoch
    }

    private func isCurrentAttempt(_ epoch: UInt64) -> Bool {
        self.activeAttemptEpoch == epoch
    }

    private func retireAttempt() {
        self.activeAttemptEpoch = nil
        self.currentTelemetryEpoch = nil
    }

    func receiveScenePhase(_ phase: TunnelScenePhase) {
        let prior = self.scenePhase
        self.scenePhase = phase
        guard self.brokerWaitEpisode != nil else { return }
        switch phase {
        case .active:
            guard prior != .active else { return }
            self.brokerWaitEpisode?.pausedBecauseInactive = false
            guard self.brokerWaitEpisode != nil else { return }
            Task { @MainActor [weak self] in
                await self?.redriveFromWaitingForHome(reason: .foreground)
            }
        case .inactive, .background:
            self.brokerWaitEpisode?.pausedBecauseInactive = true
            self.cancelBrokerWaitCadence()
        }
    }

    private func startBrokerWaitEpisodeIfNeeded() {
        if self.brokerWaitEpisode == nil {
            self.brokerWaitEpisode = BrokerWaitEpisode(
                startedAt: self.clock.monotonicNow(),
                reraceCount: 0,
                nextCadenceDeadline: nil,
                pausedBecauseInactive: self.scenePhase != .active
            )
        }
        self.armBrokerWaitCadence()
    }

    private func clearBrokerWaitEpisode() {
        self.cancelBrokerWaitCadence()
        self.brokerWaitEpisode = nil
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
        guard let attemptEpoch = self.activeAttemptEpoch else { return false }
        guard let result = await self.probeConnection() else { return false }
        guard self.activeConnection?.epoch == entry.epoch, self.isCurrentAttempt(attemptEpoch) else { return false }
        guard result.alive else {
            await self.forceReconnect(reason: .probeFailed, epoch: attemptEpoch)
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

    private func cancelStage(_ kind: ConnectionStageKind) {
        guard let index = self.connectionStages.firstIndex(where: { $0.kind == kind && $0.status == .active }) else { return }
        self.connectionStages[index].status = .cancelled
        if let start = self.connectionStages[index].startTime {
            self.connectionStages[index].duration = Double((ContinuousClock.now - start) / .seconds(1))
        }
        self.diagnosticLog?.append(category: .tunnel, message: "stage: \(kind.rawValue) cancelled")
    }

    private func markUnfinishedCandidates(_ reason: UnfinishedAttemptReason) {
        for ordinal in self.candidateTelemetry.keys {
            guard self.candidateTelemetry[ordinal]?.unfinishedReason == nil else { continue }
            if case .started = self.candidateTelemetry[ordinal]?.phase {
                self.candidateTelemetry[ordinal]?.unfinishedReason = reason
                self.diagnosticLog?.append(
                    category: .tunnel,
                    message: self.candidateLine(for: ordinal, elapsed: self.elapsedCandidateMilliseconds(ordinal))
                )
            }
        }
    }

    private func elapsedCandidateMilliseconds(_ ordinal: Int) -> Int {
        guard let candidate = self.candidateTelemetry[ordinal] else { return 0 }
        return Int(candidate.startedAt.duration(to: self.clock.monotonicNow()) / .milliseconds(1))
    }

    private func candidateLine(for ordinal: Int, elapsed: Int? = nil) -> String {
        guard let candidate = self.candidateTelemetry[ordinal] else { return "candidate \(ordinal): unavailable" }
        let route: String
        switch candidate.route {
        case .directPinned: route = "direct pinned"
        case .directUnpinned: route = "direct unpinned"
        case .relay: route = "relay"
        }
        let phase: String
        if let unfinishedReason = candidate.unfinishedReason {
            phase = "unfinished (\(unfinishedReason.rawValue))"
        } else {
            switch candidate.phase {
            case .started: phase = "started"
            case .waitingForBroker: phase = "waiting for broker"
            case .transportReady: phase = "transport ready"
            case .selected: phase = "selected"
            case .failed(let failure, _): phase = "failed \(String(describing: failure))"
            case .cancelled: phase = "cancelled"
            }
        }
        let milliseconds: Int
        if let elapsed { milliseconds = elapsed } else {
            switch candidate.phase {
            case .started: milliseconds = self.elapsedCandidateMilliseconds(ordinal)
            case .waitingForBroker(let value), .transportReady(let value), .selected(let value), .failed(_, let value), .cancelled(let value):
                milliseconds = value
            }
        }
        return "candidate \(ordinal): \(route) \(phase) \(milliseconds)ms"
    }

    private func handleAttemptEvent(_ event: TunnelAttemptEvent, epoch: UInt64) {
        guard self.isCurrentAttempt(epoch), self.currentTelemetryEpoch == epoch else { return }
        let now = self.clock.monotonicNow()
        if case .started = event.phase {
            self.candidateTelemetryTotal += 1
            guard self.candidateTelemetry[event.ordinal] != nil || self.candidateTelemetry.count < maximumSnapshotCandidateLines else {
                self.telemetryCompleteness = .active
                return
            }
            self.candidateTelemetry[event.ordinal] = CandidateAttemptTelemetry(
                ordinal: event.ordinal,
                route: event.route,
                startedAt: now,
                phase: event.phase,
                unfinishedReason: nil
            )
        } else if var existing = self.candidateTelemetry[event.ordinal] {
            existing.phase = event.phase
            self.candidateTelemetry[event.ordinal] = existing
        }
        self.telemetryCompleteness = .active
        if self.candidateTelemetry[event.ordinal] != nil {
            self.diagnosticLog?.append(category: .tunnel, message: self.candidateLine(for: event.ordinal))
        }
        if case .selected = event.phase {
            self.completeStage(.raceCandidates)
        }
    }

    private func handleAttemptUpdatesFinished(epoch: UInt64) {
        guard self.isCurrentAttempt(epoch), self.currentTelemetryEpoch == epoch else { return }
        self.markUnfinishedCandidates(.ended)
        self.telemetryCompleteness = .complete
        self.diagnosticLog?.append(category: .tunnel, message: "candidate telemetry: complete")
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
        let epoch = self.beginAttempt()

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrentAttempt(epoch) {
                    self.connectTask = nil
                }
            }
            do {
                let localPort = try await self.connectWithReactiveTokenRefresh(epoch: epoch)

                if Task.isCancelled || !self.isCurrentAttempt(epoch) {
                    await self.transport.disconnect()
                    return
                }

                self.cancelConnectWatchdog()
                await Task.yield()
                guard self.isCurrentAttempt(epoch) else { return }
                let endpoint = self.endpoint(for: self.transport.connectionMode)
                self.connectionEpoch += 1
                let connectionEpoch = self.connectionEpoch
                self.state = .connected(localPort: localPort, via: endpoint)
                self.clearBrokerWaitEpisode()
                self.completeStage(.loopback)
                self.appendStage(.connected)
                self.completeStage(.connected)
                self.lastProbeAlive = nil
                self.consecutiveKeepaliveFailures = 0
                self.consecutiveNotEntitled = 0
                self.probeWatchdog.noteConnectionEstablished()
                self.startLivenessProbe(epoch: epoch)
                log.info("[solstone-swift] connected on localhost:\(localPort) via \(endpoint == .lan ? "lan" : "remote")")
                self.diagnosticLog?.append(
                    category: .tunnel,
                    message: "connected via \(endpoint == .lan ? "local network" : "remote journal") on port \(localPort)",
                    detail: self.connectionIdentityDetail(port: localPort, epoch: connectionEpoch)
                )
                if self.ownerConnectSuccessBannerArmed {
                    self.ownerConnectSuccessBannerArmed = false
                    self.diagnosticLog?.append(category: .tunnel, message: "journal connected")
                }
                self.reconnectBackoff.reset()
                self.cancelReconnect()
                let attemptEpoch = epoch
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentAttempt(attemptEpoch) else { return }
#if DEBUG && targetEnvironment(simulator)
                    if self.integrationGateRelayOnlyCandidatePolicy != nil {
                        // why: relay-only gate runs must not repopulate LAN candidates after connect; production refresh still runs below.
                        return
                    }
#endif
                    try? await self.endpointCache.refresh(viaLoopbackPort: localPort)
                }
            } catch is CancellationError {
                guard self.isCurrentAttempt(epoch) else { return }
                self.cancelConnectWatchdog()
                return
            } catch {
                if Task.isCancelled || !self.isCurrentAttempt(epoch) { return }
                self.cancelConnectWatchdog()
                self.clearBrokerWaitEpisode()
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
                    self.scheduleReconnect(for: tunnelError, epoch: epoch)
                }
            }
        }
        self.connectTask = task
        self.connectWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.connectDeadline)
            guard !Task.isCancelled else { return }
            guard self.isCurrentAttempt(epoch) else { return }
            guard case .connecting = self.state else { return }
            self.connectTask?.cancel()
            await self.transport.disconnect()
            guard case .connecting = self.state else { return }
            self.failActiveStage()
            self.state = .error(.unreachable)
            self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "connection timed out", detail: nil)
            self.pendingReconnectReason = .watchdogTimeout
            self.scheduleReconnect(for: .unreachable, epoch: epoch)
        }
        await task.value
    }

    private func connectWithReactiveTokenRefresh(epoch: UInt64) async throws -> Int {
        var didAuthRefresh = false
        var retryPairing: StoredPairing?
        while true {
            do {
                return try await self.connectTransportOnce(pairingOverride: retryPairing, epoch: epoch)
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

    private func connectTransportOnce(pairingOverride: StoredPairing? = nil, epoch: UInt64) async throws -> Int {
        self.appendStage(.prepareCandidates)
        let pairingForIdentity: StoredPairing
        if let pairingOverride {
            pairingForIdentity = pairingOverride
        } else if let pairing = try self.loadPairing() {
            pairingForIdentity = pairing
        } else {
            throw TunnelError.revoked
        }
        self.updateJournalFingerprint(from: pairingForIdentity)
        let candidates = try await self.candidateList(pairingOverride: pairingOverride)
        self.completeStage(.prepareCandidates, detail: Self.candidateCountDetail(candidates.count))

        return try await self.transport.connect(
            candidates: candidates,
            onDisconnect: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isCurrentAttempt(epoch) else { return }
                    if case .inboundClosed(let fault) = (error as? SessionError) {
                        self.inboundClosedFaultCounts[fault ?? "<unspecified>", default: 0] += 1
                    }
                    if let sessionError = error as? SessionError,
                       sessionError == .directKeepaliveMissed || sessionError == .relayKeepaliveMissed {
                        await self.forceReconnect(reason: .keepaliveMissed, epoch: epoch)
                    } else {
                        await self.forceReconnect(
                            reason: .transportClosed(error.map { self.mapTransportError($0) } ?? .muxTeardown),
                            epoch: epoch
                        )
                    }
                }
            },
            onStageChange: { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentAttempt(epoch) else { return }
                    self.handleStageChange(event, epoch: epoch)
                }
            }
        )
    }

    private func updateJournalFingerprint(from pairing: StoredPairing) {
        let digest = SHA256.hash(data: Data(pairing.instanceID.utf8))
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        let value = String(fingerprint)
        if self.journalFingerprint != value {
            self.journalFingerprint = value
            self.latestListenerObservation = nil
            self.latestStartedProbeSequenceByEpoch = [:]
        }
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
        self.clearBrokerWaitEpisode()
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
        self.retireAttempt()
        await self.transport.disconnect()
        self.diagnosticLog?.append(
            category: .tunnel,
            message: "disconnected",
            detail: self.connectionIdentityDetail(port: active?.port, epoch: active?.epoch)
        )
    }

    func cancelConnect() {
        self.cancelConnectWatchdog()
        self.clearBrokerWaitEpisode()
        self.stopLivenessProbe()
        self.connectTask?.cancel()
        self.connectTask = nil
        self.retireAttempt()
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
        if case .waitingForHome = self.state {
            await self.redriveFromWaitingForHome(reason: .manual)
            return
        }
        await self.connect()
    }

    func redriveFromWaitingForHome(reason: RedriveTrigger) async {
        guard case .waitingForHome = self.state else { return }
        if let waitingRedriveTask {
            await waitingRedriveTask.value
            return
        }
        self.nextWaitingRedriveID &+= 1
        let redriveID = self.nextWaitingRedriveID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performWaitingRedrive(reason: reason, redriveID: redriveID)
        }
        self.waitingRedriveTask = task
        self.waitingRedriveID = redriveID
        await task.value
    }

    private func performWaitingRedrive(reason: RedriveTrigger, redriveID: UInt64) async {
        defer {
            if self.waitingRedriveID == redriveID {
                self.waitingRedriveTask = nil
                self.waitingRedriveID = nil
            }
        }
        guard case .waitingForHome = self.state else { return }
        guard self.scenePhase == .active else { return }
        self.cancelBrokerWaitCadence()
        self.cancelStage(.raceCandidates)
        self.markUnfinishedCandidates(.rerace)
        self.brokerWaitEpisode?.reraceCount += 1
        let stalled = self.connectTask
        self.connectTask = nil
        self.retireAttempt()
        stalled?.cancel()
        await self.transport.disconnect()
        await stalled?.value
        guard case .waitingForHome = self.state, self.scenePhase == .active else { return }
        self.diagnosticLog?.append(category: .tunnel, message: "re-dialing", detail: reason.label)
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
        if self.activeAttemptEpoch == nil {
            _ = self.beginAttempt()
        }
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

    private func armBrokerWaitCadence() {
        guard self.scenePhase == .active,
              self.brokerWaitEpisode?.pausedBecauseInactive == false,
              self.brokerWaitCadenceTask == nil
        else { return }
        let deadline = self.clock.monotonicNow() + brokerWaitCadence
        self.brokerWaitEpisode?.nextCadenceDeadline = deadline
        self.brokerWaitCadenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clock.sleep(for: brokerWaitCadence)
            guard !Task.isCancelled, self.scenePhase == .active else { return }
            self.brokerWaitCadenceTask = nil
            await self.redriveFromWaitingForHome(reason: .cadence)
        }
    }

    private func cancelBrokerWaitCadence() {
        self.brokerWaitCadenceTask?.cancel()
        self.brokerWaitCadenceTask = nil
        self.brokerWaitEpisode?.nextCadenceDeadline = nil
    }

    private func startLivenessProbe(epoch: UInt64) {
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
                guard self.isCurrentAttempt(epoch) else {
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
                guard self.isCurrentAttempt(epoch) else {
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
                    await self.forceReconnect(reason: .probeFailed, epoch: epoch)
                    return
                }
            }
        }
    }

    private func stopLivenessProbe() {
        self.livenessProbeTask?.cancel()
        self.livenessProbeTask = nil
    }

    private func forceReconnect(reason: ReconnectReason, epoch: UInt64? = nil) async {
        if let epoch {
            guard self.isCurrentAttempt(epoch) else { return }
        }
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
        self.scheduleReconnect(for: tunnelError, epoch: epoch)
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
                        await self.forceReconnect(reason: .pathChanged, epoch: self.activeAttemptEpoch)
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
        guard let attemptEpoch = self.activeAttemptEpoch else { return nil }
        let fingerprint = self.journalFingerprint
        self.latestProbeSequence &+= 1
        let probeSequence = self.latestProbeSequence
        self.latestStartedProbeSequenceByEpoch[attemptEpoch] = probeSequence
        let clock = ContinuousClock()
        let start = clock.now
        let alive: Bool
        let detail: String
        var listenerGeneration: Int?
        if let url = self.probeURLBuilder(localPort) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            do {
                let (data, response) = try await self.probeSession.data(for: request)
                if let http = response as? HTTPURLResponse {
                    alive = 200..<300 ~= http.statusCode
                    detail = "endpoint: /app/network/api/status; status: \(http.statusCode)"
                    if alive,
                       let payload = try? JSONDecoder().decode(NetworkStatusPayload.self, from: data),
                       let generation = payload.relayListenGeneration,
                       generation >= 0 {
                        listenerGeneration = generation
                    }
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
        guard self.isCurrentAttempt(attemptEpoch), self.journalFingerprint == fingerprint else { return nil }
        self.lastProbeAlive = alive
        if let listenerGeneration,
           let fingerprint,
           self.latestStartedProbeSequenceByEpoch[attemptEpoch] == probeSequence,
           self.connectionEpoch == active?.epoch {
            self.latestListenerObservation = HomeListenerObservation(
                journalFingerprint: fingerprint,
                connectionEpoch: active?.epoch ?? self.connectionEpoch,
                probeSequence: probeSequence,
                generation: listenerGeneration,
                observedAt: self.clock.monotonicNow()
            )
        }
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

    func diagnosticSnapshotLines() -> [String] {
        let now = self.clock.monotonicNow()
        var lines = ["journal fingerprint: \(self.journalFingerprint ?? "unavailable")"]
        lines.append("scene phase: \(self.scenePhase.rawValue)")
        if let episode = self.brokerWaitEpisode {
            let age = max(episode.startedAt.duration(to: now).components.seconds, 0)
            let next: String
            if let deadline = episode.nextCadenceDeadline {
                next = "\(max(deadline.duration(to: now).components.seconds, 0))s"
            } else {
                next = "unavailable"
            }
            lines.append("broker wait: active \(age)s, reraces \(episode.reraceCount), next in \(next)")
        } else {
            lines.append("broker wait: inactive")
        }
        if let observation = self.latestListenerObservation,
           observation.journalFingerprint == self.journalFingerprint,
           observation.connectionEpoch == self.connectionEpoch {
            let age = max(observation.observedAt.duration(to: now).components.seconds, 0)
            lines.append("last known home listener: \(observation.generation) seen \(age)s ago")
        } else {
            lines.append("last known home listener: unavailable")
        }
        lines.append("candidate telemetry: \(self.telemetryCompleteness.rawValue)")
        let candidates = self.candidateTelemetry.values.sorted { $0.ordinal < $1.ordinal }
        for candidate in candidates.prefix(maximumSnapshotCandidateLines) {
            lines.append(self.candidateLine(for: candidate.ordinal))
        }
        let omitted = self.candidateTelemetryTotal - candidates.count
        if omitted > 0 {
            lines.append("candidate outcomes omitted: \(omitted)")
        }
        return lines
    }

    private func scheduleReconnect(for error: TunnelError, epoch: UInt64? = nil) {
        guard error.isRetryable, self.isNetworkSatisfied != false else { return }
        let scheduledEpoch = epoch ?? self.activeAttemptEpoch
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
                if let scheduledEpoch, !self.isCurrentAttempt(scheduledEpoch) { return }
                self.reconnectCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            if let scheduledEpoch, !self.isCurrentAttempt(scheduledEpoch) { return }
            self.reconnectCountdown = nil
            await self.connect()
        }
    }

    private static func displaySeconds(for duration: Duration) -> Int {
        let components = duration.components
        let seconds = Int(components.seconds) + (components.attoseconds > 0 ? 1 : 0)
        return max(seconds, 1)
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
                returnedRelayCandidateCount: relayCandidates.count
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

    private func handleStageChange(_ event: TransportStage, epoch: UInt64) {
#if DEBUG && targetEnvironment(simulator)
        self.integrationGateLastTransportStage = event
#endif
        switch event {
        case .preparingCandidates:
            break
        case .racing:
            self.appendStage(.raceCandidates)
        case .awaitingBroker:
            self.redriveBaselineSignature = self.currentPathStatus.map(self.pathMeaningfulSignature)
            self.state = .waitingForHome
            self.cancelConnectWatchdog()
            self.startBrokerWaitEpisodeIfNeeded()
            self.waitingRedriveTask = nil
            self.waitingRedriveID = nil
            self.diagnosticLog?.append(category: .tunnel, message: "relay candidate waiting for home")
        case .tlsHandshaking:
            if self.telemetryCompleteness == .complete || self.telemetryCompleteness == .unavailable {
                self.completeStage(.raceCandidates)
            }
            self.appendStage(.tlsHandshake)
        case .muxReady:
            self.completeStage(.tlsHandshake)
            self.appendStage(.muxReady)
            self.completeStage(.muxReady)
        case .loopbackReady(let port):
            self.appendStage(.loopback, detail: "port \(port)")
        case .failed(let message):
            _ = message
            self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "couldn't reach your journal")
        case .attemptEvent(let event):
            self.handleAttemptEvent(event, epoch: epoch)
        case .attemptUpdatesFinished:
            self.handleAttemptUpdatesFinished(epoch: epoch)
        case .attemptUpdatesUnavailable:
            self.telemetryCompleteness = .unavailable
            self.completeStage(.raceCandidates)
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
