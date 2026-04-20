// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit
import os

private let moreLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "pairing")

struct MoreView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let connectedSince: Date
    @Binding var navigateToDiagnostics: Bool
    let pairingClient: any PairingClient
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(BrainStatusMonitor.self) private var brainStatusMonitor
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @Environment(PushNotificationManager.self) private var pushManager
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(ObserverManager.self) private var observerManager
    @State private var justCopiedSnapshot = false
    @State private var snapshotCopyTask: Task<Void, Never>?
    @State private var isProbing = false
    @State private var probeResult: String?
    @State private var probeResultIsAlive = false
    @State private var showingObserverReset = false
    @State private var showingUnpairConfirm = false
    @State private var selectedBriefingTime = Calendar.current.date(
        bySettingHour: 7,
        minute: 0,
        second: 0,
        of: .now
    ) ?? .now
    @State private var briefingError: String?

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

            Section("briefing") {
                DatePicker(
                    "time",
                    selection: self.$selectedBriefingTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.compact)
                .accessibilityHint("Chooses the time for your morning briefing")

                Button("save briefing time") {
                    Task {
                        await self.saveBriefingTime()
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Saves your morning briefing time")

                if let briefingError {
                    Text(briefingError)
                        .font(.body)
                        .foregroundStyle(.red)
                }
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

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Text("settings")
                }
                .hoverEffect(.highlight)
            }

            Section("identity") {
                LabeledContent("owner", value: self.appConfig.ownerIdentity.isEmpty ? "unpaired" : self.appConfig.ownerIdentity)
                LabeledContent("device", value: self.appConfig.deviceID.isEmpty ? "unpaired" : self.appConfig.deviceID)
            }

            Section("about") {
                LabeledContent("version", value: self.versionString)
                LabeledContent("server", value: self.appConfig.serverVersion.isEmpty ? "unknown" : self.appConfig.serverVersion)
                LabeledContent("journal root", value: self.appConfig.journalRoot.isEmpty ? "unpaired" : self.appConfig.journalRoot)
            }

            Section {
                Button("unpair this device", role: .destructive) {
                    self.showingUnpairConfirm = true
                }
                .accessibilityHint("Clears this device pairing and returns to onboarding")
            }
        }
        .navigationTitle("more")
        .navigationDestination(isPresented: self.$navigateToDiagnostics) {
            DiagnosticsView()
        }
        .alert("reset observer registration?", isPresented: self.$showingObserverReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                self.observerRegistration.reset()
            }
        } message: {
            Text("This clears the stored observer key and forces a fresh registration on next use.")
        }
        .alert("unpair this device?", isPresented: self.$showingUnpairConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) {
                Task {
                    await self.unpairDevice()
                }
            }
        } message: {
            Text("This clears the paired session on this phone and returns you to onboarding.")
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
            if UserSettings.haptics {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } else {
            if UserSettings.haptics {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func refreshBrain() async {
        guard let url = VoiceServerURL.url(localPort: self.localPort, path: "/api/voice/refresh-brain") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    private func saveBriefingTime() async {
        guard let sessionKey = self.appConfig.currentSessionKey() else {
            self.briefingError = "Missing pairing session."
            return
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: self.selectedBriefingTime)
        do {
            try await self.pairingClient.setBriefingTime(
                hour: components.hour ?? 7,
                minute: components.minute ?? 0,
                tzIdentifier: TimeZone.current.identifier,
                sessionKey: sessionKey
            )
            self.briefingError = nil
        } catch {
            self.briefingError = "Unable to save briefing time."
        }
    }

    private func unpairDevice() async {
        if let sessionKey = self.appConfig.currentSessionKey(), !self.appConfig.deviceID.isEmpty {
            do {
                moreLog.info("unpair starting for device \(self.appConfig.deviceID, privacy: .public)")
                try await self.pairingClient.unpair(deviceID: self.appConfig.deviceID, sessionKey: sessionKey)
                moreLog.info("unpair request completed")
            } catch {
                moreLog.error("unpair request failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            moreLog.error("unpair skipped: missing session or device id")
        }
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
