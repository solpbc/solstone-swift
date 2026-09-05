// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let shelfLog = Logger(subsystem: "app.solstone.swift", category: "pairing")

struct ShelfPane: View {
    let presentation: ShellPanePresentation
    /// Carried through so the `your journal` pane behind this list can show the full
    /// mark card. The shelf *row* stays plain text (journal-mark.md section 7.5).
    var journalMark: JournalMark? = nil
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
        self.phonePanel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.deckGround.ignoresSafeArea())
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("shell.pane.shelf")
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
                        journalMark: self.journalMark,
                        onOpenJournal: self.onOpenJournal
                    )
                }
        }
    }

    /// The dismiss affordance follows the presentation.
    ///
    /// ⛔ **As a drawer there is no close button, deliberately** — the dimmed shell beside
    /// it is the way back, and that is the one gesture every owner already has. The
    /// previous build put a *filled capsule* labelled `done` in the bar, so the loudest
    /// control on the surface was the one for leaving it.
    /// ⚠ **In landscape the shelf fills the window, so there is no shell to tap** — and
    /// there the explicit control stays. A dismiss gesture with nothing to aim at is not
    /// a dismiss gesture.
    private var pane: some View {
        self.shelfContent
            .navigationTitle(self.presentation.isPhoneModal ? "" : self.headingString)
            .navigationBarTitleDisplayMode(.inline)
            // ⛔ Do NOT hide this bar to tidy the drawer's root: toolbar visibility
            // propagates down a NavigationStack, so hiding it here also removes the
            // BACK BUTTON from every pane a row pushes. The root's bar is empty (the
            // heading lives in the panel) and that is the correct cost.
            .toolbar {
                if self.presentation.isPhoneModal, self.isCompactHeight {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            self.onDismiss?()
                        }
                    }
                }
                if !self.presentation.isPhoneModal {
                    ToolbarItem(placement: .principal) {
                        Text(self.headingString)
                            .font(ShellFont.sectionTitle)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("shell.pane.shelf.heading")
                            .accessibilityFocused(self.$headingFocused)
                    }
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

    /// The panel's own heading, in the panel rather than in a bar.
    ///
    /// A drawer has no navigation bar to belong to, and borrowing one gave the surface
    /// a centred inline title with a button crowding it. Left-aligned and large is what
    /// a settings surface looks like on this platform.
    private var panelHeading: some View {
        Text(self.headingString)
            .font(ShellFont.display(28, relativeTo: .largeTitle))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShelfMetrics.panelPadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("shell.pane.shelf.heading")
            .accessibilityFocused(self.$headingFocused)
    }

    @ViewBuilder
    private var shelfContent: some View {
        if self.isCompactHeight {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Landscape gets the heading too. The drawer has no navigation bar
                    // to carry one, and it is the surface's only standing name — the
                    // shell contract requires every pane to have one.
                    if self.presentation.isPhoneModal {
                        self.panelHeading
                    }
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
            }
            .scrollContentBackground(.hidden)
            .background(Color.deckGround)
            .accessibilityIdentifier("shell.pane.shelf.panel")
        } else if self.presentation.isPhoneModal {
            // The drawer: rows on the panel's own ground. ⛔ No inset card and no
            // per-row separators — a card inside a panel inside a dimmed shell is
            // three surfaces to say one thing, and the rows already read as a list.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    self.panelHeading
                    self.shelfRows
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The NavigationStack this sits in paints `systemBackground` over any
            // `.background()` applied outside it, which is why the panel came out
            // white instead of the shell's own ground.
            .scrollContentBackground(.hidden)
            .background(Color.deckGround)
            .accessibilityIdentifier("shell.pane.shelf.panel")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Width of this strip is the panel width, not the modal overlay.
                Text("\u{200B}")
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
                    .accessibilityIdentifier("shell.pane.shelf.panelWidthProbe")
            }
        } else {
            List {
                self.shelfRows
            }
            .shellSurface()
            .accessibilityIdentifier("shell.pane.shelf.panel")
            .safeAreaInset(edge: .bottom, spacing: 0) {
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

    /// A shelf row carries a glyph, its name, and — where the app already knows one —
    /// the value an owner would otherwise have to open the row to read. The shipped
    /// row was a bare word, which is what made the settings root read as an
    /// unfinished list rather than the shell's second surface.
    private func shelfRow(_ destination: ShellDestination) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 16) {
                Image(systemName: destination.shelfGlyph)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.solOrangeAdaptive)
                    .frame(width: 24, alignment: .center)
                    .accessibilityHidden(true)
                Text(destination.shelfTitle)
                    .font(ShellFont.tileName)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let value = self.shelfRowValue(destination) {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if self.presentation.isPhoneModal {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, self.presentation.isPhoneModal ? ShelfMetrics.panelPadding : 0)
            .frame(
                maxWidth: .infinity,
                minHeight: self.presentation.isPhoneModal ? ShelfMetrics.rowHeight : 48,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .accessibilityLabel(destination.shelfTitle)
            .accessibilityValue(self.shelfRowValue(destination) ?? "")
        }
        // Outside a `List`, a NavigationLink paints its whole label in the accent
        // colour — the drawer's rows came out system blue. `.plain` hands the colours
        // back to the row, which sets them itself.
        .buttonStyle(.plain)
        .accessibilityIdentifier(destination.shelfRowIdentifier)
    }

    private func shelfRowValue(_ destination: ShellDestination) -> String? {
        switch destination {
        case .shelfAbout:
            AppVersion.shortVersion
        default:
            nil
        }
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
    var journalMark: JournalMark? = nil
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
                JournalMarkView(mark: self.journalMark)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

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
        self.appConfig.journalVersion.displayValue
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
