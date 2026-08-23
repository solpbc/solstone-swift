// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let shelfLog = Logger(subsystem: "app.solstone.swift", category: "pairing")

nonisolated enum ShelfPush: Hashable, Sendable {
    case journal
    case thisDevice
    case notifications
    case help
    case about
}

struct ShelfPane: View {
    @Binding var presentedPane: PresentedShellPane?
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var path = NavigationPath()

    private var headingString: String { "dev-copy: settings" }

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(geometry.size.width - 24, 320)
            HStack(spacing: 0) {
                self.panel
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                    .clipped()
                    .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Color.black.opacity(0.24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(true)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("shell.pane.shelf")
        }
        .accessibilityAction(.escape) {
            self.dismissOneLevel()
        }
        .onAppear { self.headingFocused = true }
    }

    private var panel: some View {
        NavigationStack(path: self.$path) {
            List {
                NavigationLink(value: ShelfPush.journal) {
                    Text("dev-copy: journal")
                }
                .accessibilityIdentifier("shell.pane.shelf.journal")
                .hoverEffect(.highlight)

                NavigationLink(value: ShelfPush.thisDevice) {
                    Text("dev-copy: this device")
                }
                .accessibilityIdentifier("shell.pane.shelf.thisDevice")
                .hoverEffect(.highlight)

                NavigationLink(value: ShelfPush.notifications) {
                    Text("notifications")
                }
                .accessibilityIdentifier("shell.pane.shelf.notifications")
                .hoverEffect(.highlight)

                NavigationLink(value: ShelfPush.help) {
                    Text("dev-copy: help")
                }
                .accessibilityIdentifier("shell.pane.shelf.help")
                .hoverEffect(.highlight)

                NavigationLink(value: ShelfPush.about) {
                    Text("about solstone")
                }
                .accessibilityIdentifier("shell.pane.shelf.about")
                .hoverEffect(.highlight)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Width of this strip is the panel width, not the modal overlay.
                Text("\u{200B}")
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
                    .accessibilityIdentifier("shell.pane.shelf.panel")
            }
            .navigationTitle(self.headingString)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        self.presentedPane = nil
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(self.headingString)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("shell.pane.shelf.heading")
                        .accessibilityFocused(self.$headingFocused)
                }
            }
            .navigationDestination(for: ShelfPush.self) { push in
                switch push {
                case .journal:
                    JournalSettingsPane(presentedPane: self.$presentedPane)
                case .thisDevice:
                    ThisDevicePane()
                case .notifications:
                    NotificationsPane()
                case .help:
                    HelpPane()
                case .about:
                    AboutPane()
                }
            }
        }
    }

    private func dismissOneLevel() {
        if !self.path.isEmpty {
            self.path.removeLast()
        } else {
            self.presentedPane = nil
        }
    }
}

struct JournalSettingsPane: View {
    @Binding var presentedPane: PresentedShellPane?
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ObserverRegistration.self) private var observerRegistration

    @State private var showingForgetConfirm = false
    @State private var showingPairNewConfirm = false
    @State private var showingPairFlow = false

    private var conveyURL: URL? {
        ConveyURL.rootURL(activeLocalPort: self.observerRegistration.activeLocalPort)
    }

    var body: some View {
        List {
            Section {
                Button(SourceVocabulary.openJournalLink) {
                    self.presentedPane = .journal
                }
                .disabled(self.conveyURL == nil)
                .hoverEffect(.highlight)
                .accessibilityLabel(SourceVocabulary.openJournalLink)
                .accessibilityHint("opens your journal inside the solstone app.")

                if self.conveyURL == nil {
                    Text(SourceVocabulary.notConnectedRowAffordance(isJournalPaired: self.appConfig.isPaired))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("label", value: self.appConfig.homeLabel.isEmpty ? "unpaired" : self.appConfig.homeLabel)
                LabeledContent("fingerprint", value: self.shortFingerprint)
                LabeledContent("paired", value: self.pairedAtText)

                Button("forget this journal", role: .destructive) {
                    self.showingForgetConfirm = true
                }
                .disabled(!self.appConfig.isPaired)

                Button("pair a new journal") {
                    self.showingPairNewConfirm = true
                }
            }
        }
        .alert("forget this journal?", isPresented: self.$showingForgetConfirm) {
            Button("cancel", role: .cancel) {}
            Button("forget", role: .destructive) {
                Task {
                    await self.clearPairingAndReturnToOnboarding()
                }
            }
        } message: {
            Text("this removes the pairing from this device.")
        }
        .alert("pair a new journal?", isPresented: self.$showingPairNewConfirm) {
            Button("cancel", role: .cancel) {}
            Button("continue", role: .destructive) {
                Task {
                    await self.clearPairingForNewPair()
                }
            }
        } message: {
            Text("this forgets the current journal before pairing another one.")
        }
        .sheet(isPresented: self.$showingPairFlow) {
            NavigationStack {
                PairFlowView(
                    onBack: {
                        self.showingPairFlow = false
                    },
                    onComplete: {
                        self.showingPairFlow = false
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") {
                            self.showingPairFlow = false
                        }
                    }
                }
            }
        }
    }

    private var shortFingerprint: String {
        guard !self.appConfig.caFingerprintHex.isEmpty else {
            return "unpaired"
        }
        return String(self.appConfig.caFingerprintHex.prefix(8))
    }

    private var pairedAtText: String {
        guard let pairedAt = self.appConfig.pairedAt else {
            return "unpaired"
        }
        return pairedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func clearPairingAndReturnToOnboarding() async {
        self.appConfig.clearPairing()
        self.onboardingFlow.reset()
        await self.tunnelManager.disconnect()
    }

    private func clearPairingForNewPair() async {
        self.appConfig.clearPairing()
        await self.tunnelManager.disconnect()
        self.showingPairFlow = true
    }
}

struct ThisDevicePane: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager
    @State private var showingUnpairConfirm = false

    var body: some View {
        List {
            Section("preferences") {
                Toggle("haptics", isOn: Binding(
                    get: { UserSettings.haptics },
                    set: { UserSettings.haptics = $0 }
                ))
                .accessibilityHint("Turns interface haptics on or off")
            }

            Section("diagnostics") {
                Toggle("show technical details", isOn: Binding(
                    get: { UserSettings.verboseErrors },
                    set: { UserSettings.verboseErrors = $0 }
                ))
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
    }

    private func unpairDevice() async {
        shelfLog.info("unpair clearing local SPL pairing")
        self.appConfig.clearPairing()
        self.onboardingFlow.reset()
        await self.tunnelManager.disconnect()
    }
}

struct HelpPane: View {
    var body: some View {
        ProblemReportsView(showsSupportHeader: true)
    }
}

struct AboutPane: View {
    @Environment(AppConfig.self) private var appConfig

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var server: String {
        self.appConfig.serverVersion.isEmpty ? "unknown" : self.appConfig.serverVersion
    }

    private var owner: String {
        self.appConfig.ownerIdentity.isEmpty ? "unpaired" : self.appConfig.ownerIdentity
    }

    private var device: String {
        DeviceRegistrationDescriptor.currentDisplayName()
    }

    private var journalRoot: String {
        self.appConfig.journalRoot.isEmpty ? "unpaired" : self.appConfig.journalRoot
    }

    var body: some View {
        GeometryReader { proxy in
            List {
                Section {
                    VStack(spacing: 16) {
                        Image("SolWordmark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120)

                        Text("sol pbc · agpl-3.0")
                            .font(.custom("Comfortaa-Bold", size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, max(proxy.size.height * 0.08, 32))
                }
                .listRowBackground(Color.clear)

                Section {
                    LabeledContent("version", value: self.version)
                    LabeledContent("build", value: self.build)
                    LabeledContent("journal", value: self.server)
                    LabeledContent("owner", value: self.owner)
                    LabeledContent("device", value: self.device)
                    LabeledContent("journal root", value: self.journalRoot)
                }
            }
        }
    }
}
