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
    @State private var selectedTab = AppTab.today
    @State private var lastPortalTab = AppTab.today
    @State private var navigateToDiagnostics = false
    @State private var connectedSince = Date()

    enum AppTab: Hashable {
        case today, ask, sense, more

        var route: String {
            switch self {
            case .today: "today"
            case .ask: "ask"
            case .sense, .more: ""
            }
        }

        var iconName: String {
            switch self {
            case .today: "sun.max"
            case .ask: "bubble.left.and.questionmark"
            case .sense: "ear"
            case .more: "ellipsis.circle"
            }
        }

        var label: String {
            switch self {
            case .today: "today"
            case .ask: "ask"
            case .sense: "sense"
            case .more: "more"
            }
        }

        var shortcutKey: Character {
            switch self {
            case .today: "1"
            case .ask: "2"
            case .sense: "3"
            case .more: "4"
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
        TabView(selection: self.$selectedTab) {
            self.portalTab(for: .today)
                .tag(AppTab.today)
                .tabItem {
                    Label(AppTab.today.label, systemImage: AppTab.today.iconName)
                }
                .keyboardShortcut(KeyEquivalent(AppTab.today.shortcutKey), modifiers: .command)

            self.portalTab(for: .ask)
                .tag(AppTab.ask)
                .tabItem {
                    Label(AppTab.ask.label, systemImage: AppTab.ask.iconName)
                }
                .keyboardShortcut(KeyEquivalent(AppTab.ask.shortcutKey), modifiers: .command)

            NavigationStack {
                Text("sense")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .tag(AppTab.sense)
            .tabItem {
                Label(AppTab.sense.label, systemImage: AppTab.sense.iconName)
            }
            .keyboardShortcut(KeyEquivalent(AppTab.sense.shortcutKey), modifiers: .command)

            NavigationStack {
                MoreView(
                    localPort: self.localPort,
                    via: self.via,
                    connectedSince: self.connectedSince,
                    navigateToDiagnostics: self.$navigateToDiagnostics
                )
            }
            .tag(AppTab.more)
            .tabItem {
                Label(AppTab.more.label, systemImage: AppTab.more.iconName)
            }
            .keyboardShortcut(KeyEquivalent(AppTab.more.shortcutKey), modifiers: .command)
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .bottomLeading) {
            self.healthDot
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            if self.tunnelManager.state.isConnected {
                VoiceButton(localPort: self.localPort)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            self.portalPage.load(port: self.localPort)
            self.handleTabSelection(self.selectedTab)
        }
        .onChange(of: self.localPort) { _, port in
            self.portalPage.load(port: port)
        }
        .onChange(of: self.selectedTab) { _, tab in
            self.handleTabSelection(tab)
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
            self.handlePortalRoute(route)
        }
    }

    @ViewBuilder
    private func portalTab(for _: AppTab) -> some View {
        ZStack {
            PortalWebView(portalPage: self.portalPage)
                .ignoresSafeArea(edges: .top)

            if !self.tunnelManager.state.isConnected {
                self.reconnectOverlay
            }

            if self.tunnelManager.state.isConnected && !self.portalPage.isReady {
                self.loadingOverlay
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

    private func tabForRoute(_ route: String, currentPortalTab: AppTab) -> AppTab {
        if route.hasPrefix("today") { return .today }
        if route.hasPrefix("ask") { return .ask }
        if route.hasPrefix("entity/") { return currentPortalTab }
        return .today
    }

    private func handleTabSelection(_ tab: AppTab) {
        switch tab {
        case .today, .ask:
            self.lastPortalTab = tab
            if !self.portalPage.currentRoute.hasPrefix(tab.route) {
                self.portalPage.navigate(to: tab.route)
            }
        case .sense, .more:
            break
        }
    }

    private func handlePortalRoute(_ route: String) {
        let matchedTab = self.tabForRoute(route, currentPortalTab: self.lastPortalTab)
        if matchedTab == .today || matchedTab == .ask {
            self.lastPortalTab = matchedTab
        }
        switch self.selectedTab {
        case .today, .ask:
            if matchedTab != self.selectedTab {
                self.selectedTab = matchedTab
            }
        case .sense, .more:
            break
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
