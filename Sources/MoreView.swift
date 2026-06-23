// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit
import os

private let moreLog = Logger(subsystem: "app.solstone.swift", category: "pairing")

struct MoreView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let connectedSince: Date
    @Binding var navigateToDiagnostics: Bool
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(BrainStatusMonitor.self) private var brainStatusMonitor
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @Environment(PushNotificationManager.self) private var pushManager
    @Environment(\.openURL) private var openURL
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(ObserverManager.self) private var observerManager
    @State private var justCopiedSnapshot = false
    @State private var snapshotCopyTask: Task<Void, Never>?
    @State private var isProbing = false
    @State private var probeCheckedAt: Date?
    @State private var probeAlive = false
    @State private var probeMilliseconds = 0
    @State private var showingObserverReset = false
    @State private var showingUnpairConfirm = false
    @State private var showingConnectJournal = false

    private var serverHost: String {
        self.appConfig.host
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

    private var networkStatusText: String {
        guard let status = self.tunnelManager.currentPathStatus else {
            return "unknown"
        }
        let iface: String
        if status.isWiFi {
            iface = "wifi"
        } else if status.isCellular {
            iface = "cellular"
        } else {
            iface = "other"
        }
        var parts = [iface, status.isSatisfied ? "satisfied" : "unsatisfied"]
        if status.isExpensive {
            parts.append("expensive")
        }
        if status.isConstrained {
            parts.append("constrained")
        }
        return parts.joined(separator: " · ")
    }

    private var probeDisplay: String? {
        guard let checkedAt = self.probeCheckedAt else { return nil }
        let secondsAgo = Date().timeIntervalSince(checkedAt)
        return SourceVocabulary.probeChecked(
            alive: self.probeAlive,
            milliseconds: self.probeMilliseconds,
            relative: SourceVocabulary.probeRelativeLabel(secondsAgo: secondsAgo)
        )
    }

    private var probeDisplayColor: Color {
        self.probeAlive ? .green : .orange
    }

    private var permissionStatusText: String {
        switch self.pushManager.permissionState {
        case .notDetermined:
            "system: not requested"
        case .authorized:
            "system: authorized"
        case .denied:
            "system: denied"
        case .provisional:
            "system: provisional"
        }
    }

    private var registrationStatusText: String {
        switch self.pushManager.registrationState {
        case .idle:
            "registration: idle"
        case .registering:
            "registration: registering"
        case .registered:
            "registration: registered"
        case .failed(let reason):
            "registration: failed — \(reason)"
        }
    }

    private var observerStateText: String {
        switch self.observerManager.state {
        case .idle:
            "idle"
        case .starting:
            "starting"
        case .active:
            "active"
        case .stopping:
            "stopping"
        case .error(let error):
            "error — \(error.message)"
        }
    }

    private var observerRegistrationText: String {
        switch self.observerRegistration.state {
        case .idle:
            "idle"
        case .registering:
            "registering"
        case .registered:
            "registered"
        case .failed(let reason):
            "failed — \(reason)"
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Text("settings")
                }
                .hoverEffect(.highlight)
            }

            if !self.appConfig.isPaired {
                Section {
                    Button("connect a journal") {
                        self.showingConnectJournal = true
                    }
                    .hoverEffect(.highlight)
                    .accessibilityHint("opens journal connection options")
                }
            }

            if self.appConfig.isPaired {
                Section {
                    LabeledContent("method", value: self.via == .lan ? "local network" : "remote journal")
                    LabeledContent("journal", value: self.serverHost)
                    LabeledContent("uptime") {
                        Text(self.connectedSince, style: .timer)
                    }
                    LabeledContent("status") {
                        let line = SourceVocabulary.standingSyncLine(
                            health: self.tunnelManager.connectionHealth,
                            syncing: self.observerUploader.pendingCount > 0
                        )
                        HStack(spacing: 6) {
                            Circle()
                                .fill(self.healthColor)
                                .frame(width: 8, height: 8)
                            Text(line)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("status: \(line)")
                    }
                } header: {
                    Text(self.justCopiedSnapshot ? "copied" : SourceVocabulary.yourJournalSection)
                        .onLongPressGesture {
                            self.copySnapshot()
                        }
                        .accessibilityHint("long press to copy diagnostic snapshot")
                }
            }

            Section {
                let conveyURL = ConveyURL.rootURL(activeLocalPort: self.observerRegistration.activeLocalPort)
                Button(SourceVocabulary.openJournalLink) {
                    if let conveyURL {
                        self.openURL(conveyURL)
                    }
                }
                .disabled(conveyURL == nil)
                .hoverEffect(.highlight)
                .accessibilityLabel(SourceVocabulary.openJournalLink)
                .accessibilityHint("Opens your journal in the browser.")

                if conveyURL == nil {
                    Text(SourceVocabulary.notConnectedRowAffordance)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("diagnostics") {
                LabeledContent("reconnects", value: "\(self.tunnelManager.reconnectCount)")
                    .accessibilityLabel("reconnect count: \(self.tunnelManager.reconnectCount)")

                LabeledContent("network") {
                    Text(self.networkStatusText)
                }
                .accessibilityLabel("network: \(self.networkStatusText)")

                LabeledContent(SourceVocabulary.journalTunnel) {
                    Text(self.tunnelManager.state.isConnected ? "running" : "n/a")
                        .foregroundStyle(self.tunnelManager.state.isConnected ? .primary : .secondary)
                }
                .accessibilityLabel("\(SourceVocabulary.journalTunnel): \(self.tunnelManager.state.isConnected ? "running" : "not available")")

                Button {
                    Task {
                        await self.runProbe()
                    }
                } label: {
                    HStack {
                        Text(SourceVocabulary.checkConnection)
                        Spacer()
                        if self.isProbing {
                            ProgressView()
                                .controlSize(.small)
                        } else if let result = self.probeDisplay {
                            Text(result)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(self.probeDisplayColor)
                        }
                    }
                }
                .disabled(self.isProbing || !self.tunnelManager.state.isConnected)
                .accessibilityLabel(SourceVocabulary.checkConnection)
                .accessibilityHint(self.isProbing ? "probing in progress" : "tap to test connection health")
                .hoverEffect(.highlight)

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Text("event log")
                }
                .hoverEffect(.highlight)

                NavigationLink {
                    BLEDiagnosticView()
                } label: {
                    Text("omi ble harness")
                }
                .hoverEffect(.highlight)
            }

            Section("notifications") {
                LabeledContent("permission", value: self.permissionStatusText)
                    .accessibilityLabel(self.permissionStatusText)

                LabeledContent("registration", value: self.registrationStatusText)
                    .accessibilityLabel(self.registrationStatusText)

                Button("enable notifications") {
                    Task {
                        await self.pushManager.requestAuthorization()
                    }
                }
                .disabled(self.pushManager.permissionState == .authorized || self.pushManager.permissionState == .provisional)
                .accessibilityLabel("enable notifications")
                .hoverEffect(.highlight)

                Button("send test notification") {
                    Task {
                        _ = await self.pushManager.sendTestNotification()
                    }
                }
                .disabled(self.pushManager.activeLocalPort == nil)
                .accessibilityLabel("send test notification")
                .hoverEffect(.highlight)
            }

            Section("preferences") {
                Toggle("haptics", isOn: Binding(
                    get: { UserSettings.haptics },
                    set: { UserSettings.haptics = $0 }
                ))
                .accessibilityHint("Turns interface haptics on or off")
            }

            Section("observer") {
                LabeledContent("state", value: self.observerStateText)
                LabeledContent("registration", value: self.observerRegistrationText)
                LabeledContent("last upload") {
                    if let lastUploadAt = self.observerUploader.lastUploadAt {
                        Text(lastUploadAt, style: .time)
                    } else {
                        Text("none")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("pending", value: "\(self.observerUploader.pendingCount)")
                LabeledContent("failed", value: "\(self.observerUploader.failedCount)")

                Button(role: .destructive) {
                    self.showingObserverReset = true
                } label: {
                    Text("reset observer registration")
                }
                .hoverEffect(.highlight)
            }

            Section("identity") {
                LabeledContent("owner", value: self.appConfig.ownerIdentity.isEmpty ? "unpaired" : self.appConfig.ownerIdentity)
                LabeledContent("device", value: self.appConfig.deviceID.isEmpty ? "unpaired" : self.appConfig.deviceID)
            }

            Section("about") {
                NavigationLink {
                    AboutView()
                } label: {
                    Text("about solstone")
                }
                .accessibilityHint("Opens an about screen with app, journal, and credits")

                LabeledContent("version", value: self.versionString)
                LabeledContent("journal", value: self.appConfig.serverVersion.isEmpty ? "unknown" : self.appConfig.serverVersion)
                LabeledContent("journal root", value: self.appConfig.journalRoot.isEmpty ? "unpaired" : self.appConfig.journalRoot)
            }

            if self.appConfig.isPaired {
                Section {
                    Button("unpair this device", role: .destructive) {
                        self.showingUnpairConfirm = true
                    }
                    .accessibilityHint("Clears this device pairing and returns to onboarding")
                }
            }
        }
        .navigationTitle(SourceVocabulary.yourSolstoneTitle)
        .navigationDestination(isPresented: self.$navigateToDiagnostics) {
            DiagnosticsView()
        }
        .alert("reset observer registration?", isPresented: self.$showingObserverReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                self.observerRegistration.reset()
            }
        } message: {
            Text("this clears the stored observer key and forces a fresh registration on next use.")
        }
        .alert("unpair this device?", isPresented: self.$showingUnpairConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) {
                Task {
                    await self.unpairDevice()
                }
            }
        } message: {
            Text("this clears the paired session on this phone and returns you to onboarding.")
        }
        .onDisappear {
            self.snapshotCopyTask?.cancel()
        }
        .sheet(isPresented: self.$showingConnectJournal) {
            ConnectJournalSheet(isPresented: self.$showingConnectJournal)
        }
    }

    private func runProbe() async {
        self.isProbing = true
        let result = await self.tunnelManager.probeConnection()
        self.isProbing = false
        guard let (alive, latency) = result else { return }
        let milliseconds = Int(latency.components.seconds) * 1000
            + Int(latency.components.attoseconds / 1_000_000_000_000_000)
        self.probeAlive = alive
        self.probeMilliseconds = milliseconds
        self.probeCheckedAt = Date()
        if alive {
            if UserSettings.haptics {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } else {
            if UserSettings.haptics {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func unpairDevice() async {
        moreLog.info("unpair clearing local SPL pairing")
        self.appConfig.clearPairing()
        self.onboardingFlow.reset()
        await self.tunnelManager.disconnect()
    }

    private func copySnapshot() {
        let text = self.diagnosticLog.snapshot(
            tunnel: self.tunnelManager,
            voice: self.voiceManager,
            brain: self.brainStatusMonitor
        )
        UIPasteboard.general.string = text
        if UserSettings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
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
