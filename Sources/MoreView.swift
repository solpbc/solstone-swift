// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
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
    @Environment(PushNotificationManager.self) private var pushManager
    @Environment(ObserverRegistration.self) private var observerRegistration
    @State private var showingUnpairConfirm = false
    @State private var showingConnectJournal = false
    @State private var showingJournal = false

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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

            Section {
                let conveyURL = ConveyURL.rootURL(activeLocalPort: self.observerRegistration.activeLocalPort)
                Button(SourceVocabulary.openJournalLink) {
                    self.showingJournal = true
                }
                .disabled(conveyURL == nil)
                .hoverEffect(.highlight)
                .accessibilityLabel(SourceVocabulary.openJournalLink)
                .accessibilityHint("opens your journal inside the solstone app.")
                .sheet(isPresented: self.$showingJournal) {
                    InAppJournalView()
                }

                if conveyURL == nil {
                    Text(SourceVocabulary.notConnectedRowAffordance(isJournalPaired: self.appConfig.isPaired))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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

            Section("identity") {
                LabeledContent("owner", value: self.appConfig.ownerIdentity.isEmpty ? "unpaired" : self.appConfig.ownerIdentity)
                LabeledContent("device", value: DeviceRegistrationDescriptor.currentDisplayName())
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
        .onAppear { _ = (self.localPort, self.via, self.connectedSince) }
        .navigationTitle(SourceVocabulary.yourSolstoneTitle)
        .navigationDestination(isPresented: self.$navigateToDiagnostics) {
            DiagnosticsView()
        }
        .alert("unpair this device?", isPresented: self.$showingUnpairConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) {
                Task {
                    await self.unpairDevice()
                }
            }
        } message: {
            Text("this clears the paired session on this device and returns you to setup.")
        }
        .sheet(isPresented: self.$showingConnectJournal) {
            ConnectJournalSheet(isPresented: self.$showingConnectJournal)
        }
    }

    private func unpairDevice() async {
        moreLog.info("unpair clearing local SPL pairing")
        self.appConfig.clearPairing()
        self.onboardingFlow.reset()
        await self.tunnelManager.disconnect()
    }
}
