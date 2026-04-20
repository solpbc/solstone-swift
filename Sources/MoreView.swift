// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct MoreView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let connectedSince: Date
    @Binding var navigateToDiagnostics: Bool
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(BrainStatusMonitor.self) private var brainStatusMonitor
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @State private var justCopiedSnapshot = false
    @State private var snapshotCopyTask: Task<Void, Never>?
    @State private var isProbing = false
    @State private var probeResult: String?
    @State private var probeResultIsAlive = false

    private var serverHost: String {
        switch self.via {
        case .lan: AppConfig.default.lanHost
        case .remote: AppConfig.default.remoteHost
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var healthColor: Color {
        switch self.tunnelManager.connectionHealth {
        case .healthy: .green
        case .degraded: .yellow
        case .unknown: .gray
        }
    }

    private var healthLabel: String {
        switch self.tunnelManager.connectionHealth {
        case .healthy: "healthy"
        case .degraded: "degraded"
        case .unknown: "unknown"
        }
    }

    private var keepaliveStatusText: String {
        switch self.tunnelManager.lastProbeAlive {
        case true: "alive"
        case false: "failed"
        case nil: "pending"
        }
    }

    private var networkStatusText: String {
        let iface: String = switch self.tunnelManager.currentInterfaceIsWiFi {
        case true: "wifi"
        case false: "cellular"
        case nil: "unknown"
        }
        let satisfied: String = switch self.tunnelManager.isNetworkSatisfied {
        case true: "satisfied"
        case false: "unsatisfied"
        case nil: "unknown"
        }
        return "\(iface) · \(satisfied)"
    }

    private var probeResultColor: Color {
        self.probeResultIsAlive ? .green : .orange
    }

    var body: some View {
        List {
            Section {
                Button("refresh brain") {
                    Task {
                        await self.refreshBrain()
                    }
                }
                .hoverEffect(.highlight)
            }

            Section {
                LabeledContent("method", value: self.via == .lan ? "local network" : "remote server")
                LabeledContent("server", value: self.serverHost)
                LabeledContent("uptime") {
                    Text(self.connectedSince, style: .timer)
                }
                LabeledContent("health") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(self.healthColor)
                            .frame(width: 8, height: 8)
                        Text(self.healthLabel)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("health: \(self.healthLabel)")
                }
            } header: {
                Text(self.justCopiedSnapshot ? "copied" : "connection")
                    .onLongPressGesture {
                        self.copySnapshot()
                    }
                    .accessibilityHint("long press to copy diagnostic snapshot")
            }

            Section("diagnostics") {
                LabeledContent("keepalive") {
                    Text(self.keepaliveStatusText)
                        .foregroundStyle(self.tunnelManager.lastProbeAlive == false ? .orange : .secondary)
                }
                .accessibilityLabel("keepalive status: \(self.keepaliveStatusText)")

                LabeledContent("reconnects", value: "\(self.tunnelManager.reconnectCount)")
                    .accessibilityLabel("reconnect count: \(self.tunnelManager.reconnectCount)")

                LabeledContent("network") {
                    Text(self.networkStatusText)
                }
                .accessibilityLabel("network: \(self.networkStatusText)")

                LabeledContent("hub-phone") {
                    Text(self.tunnelManager.state.isConnected ? "running" : "n/a")
                        .foregroundStyle(self.tunnelManager.state.isConnected ? .primary : .secondary)
                }
                .accessibilityLabel("hub-phone: \(self.tunnelManager.state.isConnected ? "running" : "not available")")

                Button {
                    Task {
                        await self.runProbe()
                    }
                } label: {
                    HStack {
                        Text("probe connection")
                        Spacer()
                        if self.isProbing {
                            ProgressView()
                                .controlSize(.small)
                        } else if let result = self.probeResult {
                            Text(result)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(self.probeResultColor)
                        }
                    }
                }
                .disabled(self.isProbing || !self.tunnelManager.state.isConnected)
                .accessibilityLabel("probe connection")
                .accessibilityHint(self.isProbing ? "probing in progress" : "tap to test connection health")
                .hoverEffect(.highlight)

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Text("event log")
                }
                .hoverEffect(.highlight)
            }

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Text("settings")
                }
                .hoverEffect(.highlight)
            }

            Section {
                LabeledContent("version", value: self.versionString)
            }
        }
        .navigationTitle("more")
        .navigationDestination(isPresented: self.$navigateToDiagnostics) {
            DiagnosticsView()
        }
        .onDisappear {
            self.snapshotCopyTask?.cancel()
        }
    }

    private func runProbe() async {
        self.isProbing = true
        self.probeResult = nil
        let result = await self.tunnelManager.probeConnection()
        self.isProbing = false
        guard let (alive, latency) = result else { return }
        let milliseconds = Int(latency.components.seconds) * 1000
            + Int(latency.components.attoseconds / 1_000_000_000_000_000)
        self.probeResultIsAlive = alive
        self.probeResult = alive ? "ok · \(milliseconds)ms" : "failed · \(milliseconds)ms"
        if alive {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func refreshBrain() async {
        guard let url = VoiceServerURL.url(localPort: self.localPort, path: "/api/voice/refresh-brain") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    private func copySnapshot() {
        let text = self.diagnosticLog.snapshot(
            tunnel: self.tunnelManager,
            voice: self.voiceManager,
            brain: self.brainStatusMonitor
        )
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.snapshotCopyTask?.cancel()
        withAnimation(.easeInOut) {
            self.justCopiedSnapshot = true
        }
        self.snapshotCopyTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                withAnimation(.easeInOut) {
                    self.justCopiedSnapshot = false
                }
            }
        }
    }
}
