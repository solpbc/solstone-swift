// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "ui")

struct ContentView: View {
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @Environment(BannerPresenter.self) private var bannerPresenter
    @Environment(PushNotificationManager.self) private var pushManager
    private let appConfig = AppConfig.default
    @State private var showSettings = false
    @State private var hasConnected = false
    @State private var lastPort: Int = 0
    @State private var lastVia: ConnectionEndpoint = .lan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isIntegrationMode: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--integration-test")
            || ProcessInfo.processInfo.arguments.contains("--integration-test-live")
#else
        false
#endif
    }

    private var isPlaceholderMode: Bool {
        self.appConfig.isPlaceholder && !self.isIntegrationMode
    }

    private var shouldShowMainTab: Bool {
        self.isPlaceholderMode || self.hasConnected || self.tunnelManager.state.isConnected
    }

    private var effectivePort: Int {
        if case .connected(let port, _) = self.tunnelManager.state {
            return port
        }
        return self.lastPort
    }

    private var effectiveVia: ConnectionEndpoint {
        if case .connected(_, let via) = self.tunnelManager.state {
            return via
        }
        return self.lastVia
    }

    var body: some View {
        Group {
            if self.shouldShowMainTab {
                MainTabView(
                    localPort: self.effectivePort,
                    via: self.effectiveVia,
                    isPlaceholderMode: self.isPlaceholderMode,
                    onOpenSettings: { self.showSettings = true }
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    if self.isPlaceholderMode {
                        PlaceholderShellBanner()
                    }
                }
            } else {
                ConnectingView(
                    state: self.tunnelManager.state,
                    hasHostKeyMismatch: self.tunnelManager.hasHostKeyMismatch,
                    onAcceptKey: {
                        Task {
                            await self.tunnelManager.acceptNewHostKey()
                        }
                    },
                    onOpenSettings: {
                        self.showSettings = true
                    },
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
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            BannerOverlay()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: self.tunnelManager.state.isConnected)
        .sheet(isPresented: self.$showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") {
                                self.showSettings = false
                            }
                        }
                    }
            }
        }
        .onChange(of: self.tunnelManager.state) { _, newState in
            if case .connected(let port, let via) = newState {
                self.hasConnected = true
                self.lastPort = port
                self.lastVia = via
                Task {
                    await self.pushManager.handleTunnelConnected(localPort: port)
                }
            } else {
                self.pushManager.activeLocalPort = nil
            }
            let message: String? = switch newState {
            case .connecting(let via):
                via == .lan ? "connecting via local network" : "connecting via remote server"
            case .connected(_, let via):
                via == .lan ? "connected via local network" : "connected via remote server"
            case .error(let error):
                "connection error, \(error.userMessage)"
            case .disconnected:
                "disconnected"
            }
            if let message {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
            switch newState {
            case .connected:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .error(let error):
                if case .hostKeyMismatch = error {
                    // host-key mismatch fires warning haptic via separate onChange
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            default:
                break
            }
        }
        .onChange(of: self.tunnelManager.hasHostKeyMismatch) { _, newValue in
            if newValue {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        .onChange(of: self.diagnosticLog.events.count) {
            self.bannerPresenter.processNewEvents()
        }
        .onChange(of: self.tunnelManager.state.isConnected) { _, isConnected in
            if !isConnected {
                self.bannerPresenter.clearAll()
            }
        }
        .onChange(of: self.voiceManager.state) { _, _ in
            self.bannerPresenter.dismissInfoIfVoiceActive()
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--ui-test") {
                self.hasConnected = true
                self.lastPort = 0
                self.lastVia = .lan
                return
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--integration-test") {
                let mockPort = Int(ProcessInfo.processInfo.environment["MOCK_PORT"] ?? "") ?? 7071
                self.tunnelManager.forceConnected(port: mockPort, via: .lan)
                self.hasConnected = true
                self.lastPort = mockPort
                self.lastVia = .lan
                Task {
                    await self.pushManager.handleTunnelConnected(localPort: mockPort)
                }
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--integration-test-live") {
                let livePort = Int(ProcessInfo.processInfo.environment["LIVE_PORT"] ?? "") ?? 7071
                self.tunnelManager.forceConnected(port: livePort, via: .lan)
                self.hasConnected = true
                self.lastPort = livePort
                self.lastVia = .lan
                Task {
                    await self.pushManager.handleTunnelConnected(localPort: livePort)
                }
                return
            }
#endif
            if self.isPlaceholderMode {
                log.info("ContentView: placeholder AppConfig, skipping tunnel (Wave 5 onboarding)")
                return
            }
            self.tunnelManager.startNetworkMonitoring()
            log.info("[solstone-swift] onAppear state=\(self.tunnelManager.state)")
            if case .disconnected = self.tunnelManager.state {
                log.info("[solstone-swift] launching connect task")
                Task {
                    await self.tunnelManager.connect()
                }
            }
        }
    }
}

private struct PlaceholderShellBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(Color.solOrangeAccessible)
            Text("onboarding pending — wave 5")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }
}

private struct BannerOverlay: View {
    @Environment(BannerPresenter.self) private var bannerPresenter

    var body: some View {
        Group {
            if let item = self.bannerPresenter.currentBanner {
                BannerView(
                    item: item,
                    onTap: { self.bannerPresenter.tap() },
                    onDismiss: {
                        withAnimation {
                            self.bannerPresenter.dismiss()
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 60)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: self.bannerPresenter.currentBanner?.id)
        .allowsHitTesting(self.bannerPresenter.currentBanner != nil)
    }
}

struct ConnectingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @ScaledMetric(relativeTo: .body) private var stackSpacing: CGFloat = 24
    let state: TunnelState
    let hasHostKeyMismatch: Bool
    let onAcceptKey: () -> Void
    let onOpenSettings: () -> Void
    let onRetry: () -> Void
    let reconnectCountdown: Int?
    let consecutiveWiFiFailures: Int
    let currentInterfaceIsWiFi: Bool
    let connectionStages: [ConnectionStage]
    @ScaledMetric(relativeTo: .title) private var solRingSize: CGFloat = 72
    @AppStorage("connectionDetailsExpanded") private var detailsExpanded = false

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    @ViewBuilder
    private var stageListView: some View {
        if !self.connectionStages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(self.connectionStages) { stage in
                    HStack(spacing: 8) {
                        Group {
                            switch stage.status {
                            case .active:
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 10, height: 10)
                            case .done:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 13))
                            case .failed:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: 13))
                            }
                        }
                        .frame(width: 16)

                        Text(self.stageLabel(for: stage))
                            .font(.footnote)
                            .foregroundStyle(stage.status == .active ? .primary : .secondary)

                        Spacer()

                        if stage.status == .done, let duration = stage.duration {
                            Text(String(format: "%.1fs", duration))
                                .font(.footnote.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(self.stageAccessibilityLabel(for: stage))
                    .transition(.opacity)

                    if stage.kind == .startHubPhone, stage.status == .failed,
                       let detail = stage.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                            .padding(.leading, 24)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func stageLabel(for stage: ConnectionStage) -> String {
        switch stage.kind {
        case .lanProbe:
            if stage.status == .failed { return "LAN unavailable" }
            return "LAN probe"
        case .sshConnect:
            return "ssh connect"
        case .startHubPhone:
            if stage.status == .failed {
                return "hub-phone failed to start"
            }
            return "start hub-phone"
        case .portForward:
            return "port forwarding"
        case .connected:
            return "connected"
        }
    }

    private func stageAccessibilityLabel(for stage: ConnectionStage) -> String {
        let statusText: String
        switch stage.status {
        case .active:
            statusText = "in progress"
        case .done:
            statusText = "complete"
        case .failed:
            statusText = "failed"
        }
        let label = self.stageLabel(for: stage)
        if stage.status == .done, let duration = stage.duration {
            return "\(statusText), \(label), \(String(format: "%.1f", duration)) seconds"
        }
        return "\(statusText), \(label)"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: self.stackSpacing) {
                    HStack(spacing: 12) {
                        Image("SolRing")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: solRingSize, height: solRingSize)
                            .opacity(self.isPulsing && !self.reduceMotion ? 0.5 : 1.0)
                            .animation(
                                self.isConnecting && !self.reduceMotion
                                    ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                                    : nil,
                                value: self.isPulsing
                            )
                            .onAppear {
                                if self.isConnecting && !self.reduceMotion {
                                    self.isPulsing = true
                                }
                            }
                            .onChange(of: self.isConnecting) { _, connecting in
                                if connecting && !self.reduceMotion {
                                    self.isPulsing = true
                                } else {
                                    self.isPulsing = false
                                }
                            }
                        Text("solstone")
                            .font(.custom("Comfortaa-Bold", size: 28))
                            .foregroundStyle(Color.solOrangeAccessible)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("solstone by sol pbc")

                    switch self.state {
                    case .connecting(let via):
                        ProgressView()
                            .accessibilityLabel("connecting to server")
                        Text(via == .lan ? "connecting (LAN)…" : "connecting (remote)…")
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.detailsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("details")
                                    .font(.footnote)
                                Image(systemName: self.detailsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(self.detailsExpanded ? "hide connection details" : "show connection details")
                        .accessibilityHint("toggles stage-by-stage connection progress")
                        if self.detailsExpanded {
                            self.stageListView
                        }
                    case .error(let error):
                        VStack(spacing: 8) {
                            Image(systemName: error.iconName)
                                .font(.title)
                                .foregroundStyle(Color.solOrange)
                            Text(error.userMessage)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("connection error, \(error.userMessage.lowercased())")
                        if self.detailsExpanded {
                            self.stageListView
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.detailsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("details")
                                    .font(.footnote)
                                Image(systemName: self.detailsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(self.detailsExpanded ? "hide connection details" : "show connection details")
                        if let countdown = self.reconnectCountdown {
                            Text("reconnecting in \(countdown)s")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("reconnecting in \(countdown) seconds")
                        }
                        if error.isRetryable && self.currentInterfaceIsWiFi && self.consecutiveWiFiFailures >= 2 {
                            Text("your WiFi network may require sign-in — try opening your browser to complete any captive portal login")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        if case .hostKeyMismatch = error {
                            Text("the server's SSH key doesn't match what was previously saved — this can happen after a server reinstall or configuration change")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        if self.hasHostKeyMismatch {
                            Button("accept new host key", action: self.onAcceptKey)
                                .buttonStyle(.borderedProminent)
                                .accessibilityHint("trusts the new server key and reconnects")
                        }
                        Group {
                            if self.hasHostKeyMismatch {
                                Button("try again", action: self.onRetry)
                                    .buttonStyle(.bordered)
                            } else {
                                Button("try again", action: self.onRetry)
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .accessibilityHint("attempts to reconnect to the server")
                        Button("settings", action: self.onOpenSettings)
                            .buttonStyle(.bordered)
                            .accessibilityHint("opens app settings")
                    case .disconnected:
                        Text("disconnected")
                            .foregroundStyle(.secondary)
                        Button("try again", action: self.onRetry)
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("attempts to reconnect to the server")
                        Button("settings", action: self.onOpenSettings)
                            .buttonStyle(.bordered)
                            .accessibilityHint("opens app settings")
                    case .connected:
                        EmptyView()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}
