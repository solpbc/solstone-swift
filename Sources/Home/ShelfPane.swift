// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let shelfLog = Logger(subsystem: "app.solstone.swift", category: "pairing")

struct ShelfPane: View {
    let presentation: ShellPanePresentation
    let onOpenJournal: () -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppConfig.self) private var appConfig
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var path: [ShellDestination] = []
    @State private var showingUnpairConfirm = false

    private var headingString: String { SourceVocabulary.settingsTitle }
    private var isCompactHeight: Bool { self.verticalSizeClass == .compact }

    @ViewBuilder
    var body: some View {
        if self.presentation.isPhoneModal {
            self.phoneDrawer
        } else {
            self.pane
                .accessibilityIdentifier("shell.pane.shelf")
                .onAppear { self.headingFocused = true }
                .unpairThisDeviceAlert(isPresented: self.$showingUnpairConfirm)
        }
    }

    private var phoneDrawer: some View {
        GeometryReader { geometry in
            Group {
                if self.isCompactHeight {
                    self.phonePanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                } else {
                    let panelWidth = min(geometry.size.width - 24, 320)
                    HStack(spacing: 0) {
                        self.phonePanel
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
                }
            }
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("shell.pane.shelf")
        }
        .accessibilityAction(.escape) {
            self.dismissOneLevel()
        }
        .onAppear { self.headingFocused = true }
        .unpairThisDeviceAlert(isPresented: self.$showingUnpairConfirm)
    }

    private var phonePanel: some View {
        NavigationStack(path: self.$path) {
            self.pane
                .navigationDestination(for: ShellDestination.self) { destination in
                    ShellDestinationView(
                        destination: destination,
                        onOpenJournal: self.onOpenJournal
                    )
                }
        }
    }

    private var pane: some View {
        self.shelfContent
            .navigationTitle(self.headingString)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if self.presentation.isPhoneModal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            self.onDismiss?()
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(self.headingString)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("shell.pane.shelf.heading")
                        .accessibilityFocused(self.$headingFocused)
                }
                if self.isCompactHeight, self.appConfig.isPaired {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("unpair this device", role: .destructive) {
                                self.showingUnpairConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint("Clears this device pairing and returns to onboarding")
                    }
                }
            }
    }

    @ViewBuilder
    private var shelfContent: some View {
        if self.isCompactHeight {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ],
                    spacing: 12
                ) {
                    self.shelfRows
                }
                .padding()
            }
            .accessibilityIdentifier("shell.pane.shelf.panel")
        } else {
            List {
                self.shelfRows
            }
            .accessibilityIdentifier("shell.pane.shelf.panel")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Width of this strip is the panel width, not the modal overlay.
                Text("\u{200B}")
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
                    .accessibilityIdentifier("shell.pane.shelf.panelWidthProbe")
            }
        }
    }

    @ViewBuilder
    private var shelfRows: some View {
        self.shelfRow(.shelfJournal)
            .hoverEffect(.highlight)
        self.shelfRow(.shelfThisDevice)
            .hoverEffect(.highlight)
        self.shelfRow(.shelfNotifications)
            .hoverEffect(.highlight)
        self.shelfRow(.shelfHelp)
            .hoverEffect(.highlight)
        self.shelfRow(.shelfAbout)
            .hoverEffect(.highlight)
    }

    private func shelfRow(_ destination: ShellDestination) -> some View {
        NavigationLink(value: destination) {
            Text(destination.shelfTitle)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier(destination.shelfRowIdentifier)
    }

    private func dismissOneLevel() {
        if !self.path.isEmpty {
            self.path.removeLast()
        } else {
            self.onDismiss?()
        }
    }
}

struct JournalSettingsPane: View {
    let onOpenJournal: () -> Void
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager

    @State private var showingForgetConfirm = false
    @State private var showingPairNewConfirm = false
    @State private var showingPairFlow = false
    @AccessibilityFocusState private var headingFocused: Bool

    private var conveyURL: URL? {
        ConveyURL.rootURL(activeLocalPort: self.tunnelManager.activeConnection?.port)
    }

    var body: some View {
        List {
            Section {
                Button(SourceVocabulary.openJournalLink) {
                    self.onOpenJournal()
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
        .navigationTitle(ShellDestination.shelfJournal.shelfTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(ShellDestination.shelfJournal.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.pane.shelfJournal.heading")
                    .accessibilityFocused(self.$headingFocused)
            }
        }
        .onAppear { self.headingFocused = true }
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
    @State private var showingUnpairConfirm = false
    @AccessibilityFocusState private var headingFocused: Bool

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
        .navigationTitle(ShellDestination.shelfThisDevice.shelfTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(ShellDestination.shelfThisDevice.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.pane.shelfThisDevice.heading")
                    .accessibilityFocused(self.$headingFocused)
            }
        }
        .onAppear { self.headingFocused = true }
        .unpairThisDeviceAlert(isPresented: self.$showingUnpairConfirm)
    }
}

private extension View {
    func unpairThisDeviceAlert(isPresented: Binding<Bool>) -> some View {
        modifier(UnpairThisDeviceAlert(isPresented: isPresented))
    }
}

private struct UnpairThisDeviceAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager

    func body(content: Content) -> some View {
        content.alert("unpair this device?", isPresented: self.$isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) {
                Task {
                    await self.unpair()
                }
            }
        } message: {
            Text("this clears the paired session on this device and returns you to setup.")
        }
    }

    private func unpair() async {
        shelfLog.info("unpair clearing local SPL pairing")
        self.appConfig.clearPairing()
        self.onboardingFlow.reset()
        await self.tunnelManager.disconnect()
    }
}

struct HelpPane: View {
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        ProblemReportsView(showsSupportHeader: true)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(ShellDestination.shelfHelp.shelfTitle)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("shell.pane.shelfHelp.heading")
                        .accessibilityFocused(self.$headingFocused)
                }
            }
            .onAppear { self.headingFocused = true }
    }
}

struct AboutPane: View {
    @Environment(AppConfig.self) private var appConfig
    @AccessibilityFocusState private var headingFocused: Bool

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
        .navigationTitle(ShellDestination.shelfAbout.shelfTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(ShellDestination.shelfAbout.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.pane.shelfAbout.heading")
                    .accessibilityFocused(self.$headingFocused)
            }
        }
        .onAppear { self.headingFocused = true }
    }
}
