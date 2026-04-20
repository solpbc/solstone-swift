// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Observation
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "tunnel")

@Observable
final class TunnelManager {
    var state: TunnelState = .disconnected
    var hasHostKeyMismatch: Bool {
        if case .error(.hostKeyMismatch) = state { return true }
        return false
    }
    @ObservationIgnored private let transport: any SSHTransporting
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval
    @ObservationIgnored private let initialRetryDelay: TimeInterval
    @ObservationIgnored private let jitterRange: ClosedRange<Double>
    var reconnectCountdown: Int?
    var consecutiveWiFiFailures: Int = 0
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    var isNetworkSatisfied: Bool?
    var currentInterfaceIsWiFi: Bool?
    var lastProbeAlive: Bool?
    var consecutiveKeepaliveFailures: Int = 0
    var reconnectCount: Int = 0
    var connectionStages: [ConnectionStage] = []
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?

    init(
        transport: any SSHTransporting = SSHTransport(),
        initialRetryDelay: TimeInterval = 2.0,
        jitterRange: ClosedRange<Double> = 0.75...1.25,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.transport = transport
        self.initialRetryDelay = initialRetryDelay
        self.retryDelay = initialRetryDelay
        self.jitterRange = jitterRange
        self.diagnosticLog = diagnosticLog
    }

    var connectionHealth: ConnectionHealth {
        switch self.state {
        case .connected:
            if self.lastProbeAlive == false { return .degraded }
            return .healthy
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

    private func failStage(_ kind: ConnectionStageKind, detail: String? = nil) {
        guard let index = self.connectionStages.firstIndex(where: { $0.kind == kind }) else { return }
        self.connectionStages[index].status = .failed
        if let start = self.connectionStages[index].startTime {
            self.connectionStages[index].duration = Double((ContinuousClock.now - start) / .seconds(1))
        }
        if let detail {
            self.connectionStages[index].detail = detail
        }
        self.diagnosticLog?.append(
            category: .tunnel,
            severity: .warning,
            message: "stage: \(kind.rawValue) failed\(detail.map { " (\($0))" } ?? "")"
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
                self.appendStage(.lanProbe)
                let useLAN = await self.transport.probeLAN()
                if Task.isCancelled { return }
                log.info("[solstone-swift] probeLAN = \(useLAN)")
                self.diagnosticLog?.append(category: .tunnel, message: "lan probe: \(useLAN ? "reachable" : "unreachable")")
                if useLAN {
                    self.completeStage(.lanProbe, detail: "reachable")
                } else {
                    self.failStage(.lanProbe, detail: "LAN unavailable")
                }
                let endpoint: ConnectionEndpoint = useLAN ? .lan : .remote
                if !useLAN {
                    self.state = .connecting(.remote)
                }
                let localPort = try await self.transport.connect(
                    endpoint: endpoint,
                    onDisconnect: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, case .connected = self.state else { return }
                            log.error("[solstone-swift] SSH channel closed unexpectedly")
                            self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "tunnel closed unexpectedly")
                            self.state = .error(.tunnelClosed)
                            await self.transport.disconnect()
                            guard case .error(.tunnelClosed) = self.state else { return }
                            self.scheduleReconnect(for: .tunnelClosed)
                        }
                    },
                    onHostKeyMismatch: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.state = .error(.hostKeyMismatch)
                        }
                    },
                    onKeepaliveResult: { [weak self] alive, failures in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let wasAlive = self.lastProbeAlive
                            self.lastProbeAlive = alive
                            self.consecutiveKeepaliveFailures = failures
                            if !alive {
                                self.diagnosticLog?.append(
                                    category: .tunnel,
                                    severity: .warning,
                                    message: "keepalive failed (strike \(failures))"
                                )
                            } else if wasAlive == false {
                                self.diagnosticLog?.append(
                                    category: .tunnel,
                                    message: "keepalive recovered"
                                )
                            }
                        }
                    },
                    onStageChange: { [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            switch event {
                            case .sshConnecting:
                                self.appendStage(.sshConnect)
                            case .sshConnected:
                                self.completeStage(.sshConnect)
                            case .startingHubPhone:
                                self.appendStage(.startHubPhone)
                            case .hubPhoneReady(let port):
                                self.completeStage(.startHubPhone, detail: "port \(port)")
                                self.diagnosticLog?.append(category: .tunnel, message: "hub-phone ready on port \(port)")
                            case .portForwarding:
                                self.appendStage(.portForward)
                            case .execOutput(let text, let isStdErr):
                                self.diagnosticLog?.append(
                                    category: .tunnel,
                                    severity: isStdErr ? .warning : .info,
                                    message: "exec \(isStdErr ? "stderr" : "stdout")",
                                    detail: text
                                )
                            case .execFailed(let stderr):
                                self.diagnosticLog?.append(
                                    category: .tunnel,
                                    severity: .error,
                                    message: "hub-phone failed to start",
                                    detail: stderr
                                )
                            }
                        }
                    }
                )
                if Task.isCancelled {
                    await self.transport.disconnect()
                    return
                }
                await Task.yield() // drain pending onStageChange callbacks
                self.state = .connected(localPort: localPort, via: endpoint)
                self.completeStage(.portForward)
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
            } catch is CancellationError {
                return
            } catch {
                log.error("[solstone-swift] connect() failed: \(error)")
                await self.transport.disconnect()
                await Task.yield() // drain pending onStageChange callbacks
                let tunnelError = (error as? TunnelError) ?? .unknown(String(describing: error))
                if let activeIndex = self.connectionStages.lastIndex(where: { $0.status == .active }) {
                    self.connectionStages[activeIndex].status = .failed
                    if let start = self.connectionStages[activeIndex].startTime {
                        self.connectionStages[activeIndex].duration = Double((ContinuousClock.now - start) / .seconds(1))
                    }
                    self.diagnosticLog?.append(
                        category: .tunnel,
                        severity: .warning,
                        message: "stage: \(self.connectionStages[activeIndex].kind.rawValue) failed"
                    )
                }
                if case .hubPhoneStartFailed(let stderr) = tunnelError, !stderr.isEmpty {
                    if let idx = self.connectionStages.lastIndex(where: { $0.kind == .startHubPhone }) {
                        // Show tail of stderr — Python tracebacks put the error at the bottom
                        let lines = stderr.split(separator: "\n")
                        self.connectionStages[idx].detail = lines.suffix(8).joined(separator: "\n")
                    }
                }
                self.state = .error(tunnelError)
                self.diagnosticLog?.append(
                    category: .tunnel,
                    severity: .error,
                    message: "connection failed",
                    detail: tunnelError.userMessage
                )
                if self.currentInterfaceIsWiFi == true {
                    self.consecutiveWiFiFailures += 1
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

    func handleTunnelFailure() async {
        guard case .connected = self.state else { return }
        log.error("[solstone-swift] tunnel failure detected by portal")
        self.diagnosticLog?.append(category: .tunnel, severity: .warning, message: "tunnel failure detected by portal")
        self.state = .error(.tunnelClosed)
        await self.transport.disconnect()
        guard case .error(.tunnelClosed) = self.state else { return }
        self.scheduleReconnect(for: .tunnelClosed)
    }

    func cancelReconnect() {
        self.retryTask?.cancel()
        self.retryTask = nil
        self.reconnectCountdown = nil
    }

    func startNetworkMonitoring() {
        guard self.pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        self.monitorTask = Task { [weak self] in
            for await path in monitor {
                guard let self else { return }
                let wasSatisfied = self.isNetworkSatisfied
                self.isNetworkSatisfied = path.status == .satisfied
                if wasSatisfied != nil, wasSatisfied != self.isNetworkSatisfied {
                    log.info("[solstone-swift] network: status \(wasSatisfied == true ? "satisfied" : "unsatisfied") → \(self.isNetworkSatisfied == true ? "satisfied" : "unsatisfied")")
                    self.diagnosticLog?.append(
                        category: .network,
                        severity: self.isNetworkSatisfied == true ? .info : .warning,
                        message: "network \(self.isNetworkSatisfied == true ? "satisfied" : "unsatisfied")"
                    )
                }

                if wasSatisfied != true && self.isNetworkSatisfied == true {
                    if case .error(let error) = self.state, error.isRetryable {
                        log.info("[solstone-swift] network: triggering retry (network restored)")
                        await self.retryNow()
                    }
                } else if wasSatisfied == true && self.isNetworkSatisfied == false {
                    log.info("[solstone-swift] network: cancelling reconnect (network lost)")
                    self.cancelReconnect()
                }

                let isWiFi = path.usesInterfaceType(.wifi)
                let wasWiFi = self.currentInterfaceIsWiFi
                self.currentInterfaceIsWiFi = isWiFi
                if !isWiFi {
                    self.consecutiveWiFiFailures = 0
                }
                if wasWiFi != nil, wasWiFi != isWiFi {
                    log.info("[solstone-swift] network: interface \(wasWiFi == true ? "WiFi" : "cellular") → \(isWiFi ? "WiFi" : "cellular")")
                    self.diagnosticLog?.append(
                        category: .network,
                        message: "interface changed to \(isWiFi ? "wifi" : "cellular")"
                    )
                }
                if wasWiFi != nil, wasWiFi != isWiFi, case .connected = self.state {
                    let alive = await self.transport.probeConnection()
                    if !alive {
                        log.info("[solstone-swift] network: connection dead after interface change, reconnecting")
                        await self.transport.disconnect()
                        self.state = .error(.tunnelClosed)
                        await self.retryNow()
                    }
                }
            }
        }
    }

    func stopNetworkMonitoring() {
        self.monitorTask?.cancel()
        self.monitorTask = nil
        self.pathMonitor?.cancel()
        self.pathMonitor = nil
        self.isNetworkSatisfied = nil
        self.currentInterfaceIsWiFi = nil
    }

    func acceptNewHostKey() async {
        do {
            try self.transport.acceptPendingHostKey()
            await self.connect()
        } catch {
            let tunnelError = (error as? TunnelError) ?? .unknown(String(describing: error))
            self.state = .error(tunnelError)
        }
    }

    func probeConnection() async -> (alive: Bool, latency: Duration)? {
        guard case .connected = self.state else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        let alive = await self.transport.probeConnection()
        let elapsed = clock.now - start
        self.lastProbeAlive = alive
        self.diagnosticLog?.append(
            category: .tunnel,
            severity: alive ? .info : .warning,
            message: "manual probe \(alive ? "alive" : "failed")",
            detail: "latency: \(elapsed)"
        )
        return (alive, elapsed)
    }

    private func scheduleReconnect(for error: TunnelError) {
        guard error.isRetryable, self.isNetworkSatisfied != false else { return }
        self.cancelReconnect()
        let jittered = self.retryDelay * Double.random(in: self.jitterRange)
        let delay = max(Int(jittered), 1)
        log.info("[solstone-swift] scheduling reconnect in \(delay)s for \(error)")
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
}
