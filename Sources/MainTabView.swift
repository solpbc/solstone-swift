// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct MainTabView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let onOpenSettings: () -> Void
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(BannerPresenter.self) private var bannerPresenter
    @Environment(PortalPage.self) private var portalPage
    @State private var selectedTab = AppTab.dashboard
    @State private var navigateToDiagnostics = false
    @State private var connectedSince = Date()

    enum AppTab: Hashable {
        case dashboard, sessions, requests, files, more

        var route: String {
            switch self {
            case .dashboard: "dashboard"
            case .sessions: "sessions"
            case .requests: "requests"
            case .files: "files"
            case .more: ""
            }
        }
    }

    @ViewBuilder
    private var reconnectOverlay: some View {
        if !self.tunnelManager.state.isConnected {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                ConnectingView(
                    state: self.tunnelManager.state,
                    hasHostKeyMismatch: self.tunnelManager.hasHostKeyMismatch,
                    onAcceptKey: {
                        Task {
                            await self.tunnelManager.acceptNewHostKey()
                        }
                    },
                    onOpenSettings: self.onOpenSettings,
                    onRetry: {
                        Task {
                            await self.tunnelManager.retryNow()
                        }
                    },
                    reconnectCountdown: self.tunnelManager.reconnectCountdown,
                    consecutiveWiFiFailures: self.tunnelManager.consecutiveWiFiFailures,
                    currentInterfaceIsWiFi: self.tunnelManager.currentInterfaceIsWiFi ?? false,
                    connectionStages: self.tunnelManager.connectionStages
                )
            }
        }
    }

    @ViewBuilder
    private var healthDot: some View {
        let health = self.tunnelManager.connectionHealth
        if health == .healthy || health == .degraded {
            Circle()
                .fill(health == .healthy ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
                .padding(.leading, 32)
                .padding(.bottom, 18)
                .accessibilityLabel("connection \(health == .healthy ? "healthy" : "degraded")")
        }
    }

    var body: some View {
        ZStack {
            PortalWebView(portalPage: self.portalPage)
                .ignoresSafeArea(edges: .top)
                .opacity(self.selectedTab == .more ? 0 : 1)
                .allowsHitTesting(self.selectedTab != .more)

            if self.selectedTab == .more {
                NavigationStack {
                    MoreView(
                        localPort: self.localPort,
                        via: self.via,
                        connectedSince: self.connectedSince,
                        navigateToDiagnostics: self.$navigateToDiagnostics
                    )
                }
            }

            if !self.tunnelManager.state.isConnected && self.selectedTab != .more {
                self.reconnectOverlay
            }

            if self.selectedTab != .more && self.tunnelManager.state.isConnected && !self.portalPage.isReady {
                self.loadingOverlay
            }
        }
        .safeAreaInset(edge: .bottom) {
            self.tabBar
        }
        .overlay(alignment: .bottomLeading) {
            self.healthDot
                .allowsHitTesting(false)
        }
        .overlay {
            if self.tunnelManager.state.isConnected {
                VoiceButton(localPort: self.localPort)
                    .padding(.bottom, 56)
            }
        }
        .onAppear {
            self.portalPage.load(port: self.localPort)
        }
        .onChange(of: self.localPort) { _, port in
            self.portalPage.load(port: port)
        }
        .onChange(of: self.selectedTab) { _, tab in
            if tab != .more {
                self.portalPage.navigate(to: tab.route)
            }
        }
        .onChange(of: self.tunnelManager.state.isConnected) { wasConnected, isConnected in
            if !wasConnected && isConnected {
                self.connectedSince = Date()
            }
        }
        .onChange(of: self.bannerPresenter.showDiagnostics) { _, show in
            if show {
                self.selectedTab = .more
                self.navigateToDiagnostics = true
                self.bannerPresenter.showDiagnostics = false
            }
        }
        .onChange(of: self.portalPage.currentRoute) { _, route in
            guard self.selectedTab != .more else { return }
            let matchedTab = self.tabForRoute(route)
            if matchedTab != self.selectedTab {
                self.selectedTab = matchedTab
            }
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Image("SolRing")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .opacity(0.3)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityLabel("loading portal")
    }

    @ViewBuilder
    private var tabBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach([AppTab.dashboard, .sessions, .requests, .files, .more], id: \.self) { tab in
                    Button {
                        self.selectedTab = tab
                        if tab != .more {
                            self.portalPage.navigate(to: tab.route)
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: self.iconName(for: tab))
                                .font(.system(size: 20))
                            Text(self.label(for: tab))
                                .font(.caption2)
                        }
                        .foregroundStyle(self.selectedTab == tab ? Color.accentColor : Color(.secondaryLabel))
                        .frame(maxWidth: .infinity)
                    }
                    .hoverEffect(.highlight)
                    .keyboardShortcut(KeyEquivalent(self.shortcutKey(for: tab)), modifiers: .command)
                    .accessibilityLabel(self.label(for: tab))
                }
            }
            .frame(height: 49)
        }
        .background(.bar)
    }

    private func tabForRoute(_ route: String) -> AppTab {
        if route.hasPrefix("sessions") { return .sessions }
        if route.hasPrefix("requests") { return .requests }
        if route.hasPrefix("files") { return .files }
        return .dashboard
    }

    private func iconName(for tab: AppTab) -> String {
        switch tab {
        case .dashboard: "globe"
        case .sessions: "play.circle"
        case .requests: "tray.full"
        case .files: "folder"
        case .more: "ellipsis.circle"
        }
    }

    private func label(for tab: AppTab) -> String {
        switch tab {
        case .dashboard: "dashboard"
        case .sessions: "sessions"
        case .requests: "requests"
        case .files: "files"
        case .more: "more"
        }
    }

    private func shortcutKey(for tab: AppTab) -> Character {
        switch tab {
        case .dashboard: "1"
        case .sessions: "2"
        case .requests: "3"
        case .files: "4"
        case .more: "5"
        }
    }
}

private struct MoreView: View {
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
        guard let url = URL(string: "http://127.0.0.1:\(self.localPort)/api/voice/refresh-brain") else { return }
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
