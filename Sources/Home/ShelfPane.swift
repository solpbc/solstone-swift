// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os
import UIKit

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
                        Button(AppStrings.ios_home_done()) {
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
                            Button(AppStrings.ios_home_unpairthisdevice(), role: .destructive) {
                                self.showingUnpairConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint(AppStrings.ios_home_showingunpairconfirm())
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
    @State private var showingJournalLives = false
    @AccessibilityFocusState private var headingFocused: Bool

    private var conveyURL: URL? {
        ConveyURL.rootURL(activeLocalPort: self.tunnelManager.activeConnection?.port)
    }

    var body: some View {
        List {
            Section {
                let identity = JournalIdentity.select(
                    isPaired: self.appConfig.isPaired,
                    sendConfirmed: self.appConfig.journalSendConfirmed,
                    mark: self.journalMark
                )
                JournalMarkView(identity: identity)
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
                .accessibilityHint(AppStrings.ios_home_opensyourjournalinsidethesolstoneapp())

                if self.conveyURL == nil {
                    Text(SourceVocabulary.notConnectedRowAffordance(isJournalPaired: self.appConfig.isPaired))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(AppStrings.ios_home_body54(), value: self.pairedAtText)

                DisclosureGroup(AppStrings.ios_migration_storageunavailable_action()) {
                    LabeledContent(SourceVocabulary.journalShelfDeviceCertificateLabel, value: self.shortFingerprint)
                    if self.appConfig.isPaired {
                        let paired = self.tunnelManager.pairedJournalAddresses()
                        if !paired.endpoints.isEmpty {
                            LabeledContent(AppStrings.ios_home_body4()) {
                                Text(verbatim: paired.endpoints
                                    .map { JournalAddress.display(host: $0.host, port: $0.port) }
                                    .joined(separator: "\n"))
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        LabeledContent(AppStrings.ios_home_route(), value: paired.relayHost.map { AppStrings.ios_home_body51("\($0)") } ?? AppStrings.ios_app_off())
                        if self.tunnelManager.state.isConnected, let connectedAddress = self.tunnelManager.connectedAddress {
                            LabeledContent(AppStrings.ios_home_body6(), value: connectedAddress)
                        }
                    }
                }

                Button(AppStrings.ios_home_reinstallnoticeforget(), role: .destructive) {
                    self.showingForgetConfirm = true
                }
                .disabled(!self.appConfig.isPaired)

                Button(AppStrings.ios_home_body52()) {
                    if self.appConfig.isPaired {
                        self.showingPairNewConfirm = true
                    } else {
                        self.showingJournalLives = true
                    }
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
        .alert(AppStrings.ios_home_headingfocused(), isPresented: self.$showingForgetConfirm) {
            Button(AppStrings.ios_migration_picker_cancel(), role: .cancel) {}
            Button(AppStrings.ios_home_body12(), role: .destructive) {
                Task {
                    await self.clearPairingAndReturnToOnboarding()
                }
            }
        } message: {
            Text(SourceVocabulary.waitingGoesToNextJournal)
        }
        .alert(AppStrings.ios_home_body53(), isPresented: self.$showingPairNewConfirm) {
            Button(AppStrings.ios_migration_picker_cancel(), role: .cancel) {}
            Button(AppStrings.ios_home_alwaysprimercontinue(), role: .destructive) {
                Task {
                    await self.clearPairingForNewPair()
                }
            }
        } message: {
            Text(AppStrings.ios_home_body60())
        }
        .sheet(isPresented: self.$showingJournalLives) {
            JournalLivesSheet(isPresented: self.$showingJournalLives)
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
                        Button(AppStrings.ios_migration_picker_cancel()) {
                            self.showingPairFlow = false
                        }
                    }
                }
            }
        }
    }

    private var shortFingerprint: String {
        guard !self.appConfig.clientCertFingerprintHex.isEmpty else {
            return AppStrings.ios_shelfpane_unpaired()
        }
        return String(self.appConfig.clientCertFingerprintHex.prefix(8))
    }

    private var pairedAtText: String {
        guard let pairedAt = self.appConfig.pairedAt else {
            return AppStrings.ios_shelfpane_unpaired()
        }
        return pairedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func clearPairingAndReturnToOnboarding() async {
        await unpairAndReturnToOnboarding(
            appConfig: self.appConfig,
            onboardingFlow: self.onboardingFlow,
            tunnelManager: self.tunnelManager
        )
    }

    private func clearPairingForNewPair() async {
        guard await unpairForNewPair(
            appConfig: self.appConfig,
            tunnelManager: self.tunnelManager
        ) else { return }
        self.showingPairFlow = true
    }
}

struct ThisDevicePane: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(DeviceMigrationOwnerModel.self) private var deviceMigrationOwner
    @State private var showingUnpairConfirm = false
    @State private var showingFreshPairOffer = false
    @State private var pendingReplacementCID: String?
    @State private var replacementPresentation: DeviceMigrationReplacementPresentation?
    @State private var pendingReplacementLabel = ""
    @State private var showingSameDeviceConfirmation = false
    @State private var sameDevicePresentation: DeviceMigrationChoicePresentation?
    @State private var showingPairFlow = false
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        List {
            Section {
                LabeledContent(AppStrings.ios_home_body10(), value: DeviceRegistrationDescriptor.currentDisplayName())
            }

            Section(AppStrings.ios_home_body56()) {
                Toggle(AppStrings.ios_home_body13(), isOn: Binding(
                    get: { UserSettings.haptics },
                    set: { UserSettings.haptics = $0 }
                ))
                .accessibilityHint(AppStrings.ios_home_haptics())
            }

            Section(AppStrings.ios_home_watchdiagnosticsblocktitle()) {
                Toggle(AppStrings.ios_home_body58(), isOn: Binding(
                    get: { UserSettings.verboseErrors },
                    set: { UserSettings.verboseErrors = $0 }
                ))
            }

            if self.appConfig.isPaired {
                if let recovery = self.tunnelManager.migrationRecoveryState {
                    Section {
                        switch recovery {
                        case .preparing:
                            Text(AppStrings.ios_lookup_migration_preparing_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_preparing_body())
                        case .offline:
                            Text(AppStrings.ios_lookup_migration_offline_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_offline_body())
                            Button(AppStrings.ios_lookup_migration_offline_action()) {
                                Task { await self.tunnelManager.connect() }
                            }
                        case .unsupported:
                            Text(AppStrings.ios_lookup_migration_unsupported_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_unsupported_body())
                            Button(AppStrings.ios_lookup_migration_unsupported_action()) {
                                Task { await self.tunnelManager.connect() }
                            }
                        case .storageUnavailable:
                            Text(AppStrings.ios_lookup_migration_storage_unavailable_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_storage_unavailable_body())
                            Button(AppStrings.ios_lookup_migration_storage_unavailable_action()) {
                                UserSettings.verboseErrors = true
                            }
                        case .keyRefused:
                            Text(AppStrings.ios_lookup_migration_key_refused_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_key_refused_body())
                            Button(AppStrings.ios_lookup_migration_key_refused_action()) {
                                self.showingPairFlow = true
                            }
                        }
                    }
                }

                if self.deviceMigrationOwner.migrationChoicePending {
                    Section {
                        LabeledContent { Text(AppStrings.ios_lookup_migration_pending_value()) } label: { Text(AppStrings.ios_lookup_migration_pending_row()) }
                        Text(AppStrings.ios_lookup_migration_choice_title()).font(.headline)
                        Text(AppStrings.ios_lookup_migration_choice_body_fallback())
                        if self.deviceMigrationOwner.migrationDecisionState == .submitting {
                            Text(AppStrings.ios_lookup_migration_deciding_title()).font(.headline)
                        } else if self.deviceMigrationOwner.migrationDecisionState == .unknown {
                            Text(AppStrings.ios_lookup_migration_decision_unknown_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_decision_unknown_body())
                            Button(AppStrings.ios_lookup_migration_decision_unknown_action()) {
                                Task { await self.deviceMigrationOwner.refresh() }
                            }
                        } else if self.deviceMigrationOwner.serverState == nil {
                            Text(AppStrings.ios_lookup_migration_offline_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_offline_body())
                            Button(AppStrings.ios_lookup_migration_offline_action()) {
                                Task { await self.deviceMigrationOwner.refresh() }
                            }
                        } else if self.deviceMigrationOwner.migrationDecisionState == .refused {
                            Text(AppStrings.ios_lookup_migration_decision_refused_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_decision_refused_body())
                            Button(AppStrings.ios_lookup_migration_decision_refused_action()) {
                                UserSettings.verboseErrors = true
                            }
                        } else if self.deviceMigrationOwner.canChooseMigration {
                            Button(AppStrings.ios_lookup_migration_choice_new()) {
                                guard let context = self.deviceMigrationOwner.migrationChoicePresentation() else { return }
                                Task { await self.deviceMigrationOwner.submitMigrationChoice(.newDevice, presentedContext: context) }
                            }
                            Button(AppStrings.ios_lookup_migration_choice_same()) {
                                self.sameDevicePresentation = self.deviceMigrationOwner.migrationChoicePresentation()
                                self.showingSameDeviceConfirmation = true
                            }
                            Button(AppStrings.ios_lookup_migration_choice_defer(), role: .cancel) {
                                self.deviceMigrationOwner.deferMigrationChoice()
                            }
                        }
                    }
                }

                if self.tunnelManager.activeConnection != nil,
                   self.deviceMigrationOwner.isFreshPairPendingVisible,
                   let offer = self.deviceMigrationOwner.freshPairOffer {
                    Section {
                        LabeledContent { Text(AppStrings.ios_lookup_migration_pending_value()) } label: { Text(AppStrings.ios_lookup_migration_pending_row()) }
                        Text(AppStrings.ios_lookup_migration_replace_offer_title()).font(.headline)
                        Text(AppStrings.ios_lookup_migration_replace_offer_body())
                        if offer.state == .submitting {
                            Text(AppStrings.ios_lookup_migration_deciding_title()).font(.headline)
                        } else if offer.state == .unknown {
                            Text(AppStrings.ios_lookup_migration_decision_unknown_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_decision_unknown_body())
                            Button(AppStrings.ios_lookup_migration_decision_unknown_action()) {
                                Task { await self.deviceMigrationOwner.refresh() }
                            }
                        } else {
                            if offer.state == .targetRemoved {
                                Text(AppStrings.ios_lookup_migration_target_missing_title()).font(.headline)
                                Text(AppStrings.ios_lookup_migration_target_missing_body())
                            } else if offer.state == .refused {
                                Text(AppStrings.ios_lookup_migration_decision_refused_title()).font(.headline)
                                Text(AppStrings.ios_lookup_migration_decision_refused_body())
                                Button(AppStrings.ios_lookup_migration_decision_refused_action()) {
                                    UserSettings.verboseErrors = true
                                }
                            }
                            Button(AppStrings.ios_lookup_migration_replace_offer_pick()) {
                                self.deviceMigrationOwner.prepareReplacementSelection()
                                Task {
                                    await self.deviceMigrationOwner.loadReplacementClients()
                                    self.showingFreshPairOffer = true
                                }
                            }
                            Button(AppStrings.ios_lookup_migration_replace_offer_keep()) {
                                self.deviceMigrationOwner.keepBothFromFreshPairOffer()
                            }
                            Button(AppStrings.ios_lookup_migration_replace_offer_defer()) {
                                self.deviceMigrationOwner.dismissReplacementOffer()
                            }
                        }
                    }
                }

                Section {
                    Button(AppStrings.ios_home_unpairthisdevice(), role: .destructive) {
                        self.showingUnpairConfirm = true
                    }
                    .accessibilityHint(AppStrings.ios_home_showingunpairconfirm())
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
        .task {
            if let connection = self.tunnelManager.activeConnection {
                await self.deviceMigrationOwner.connected(
                    localPort: connection.port,
                    connectionEpoch: connection.epoch
                )
            } else {
                await self.deviceMigrationOwner.refresh()
            }
        }
        .sheet(isPresented: self.$showingFreshPairOffer) {
            NavigationStack {
                List {
                    if self.deviceMigrationOwner.replacementListState == .empty {
                        Text(AppStrings.ios_lookup_migration_picker_empty())
                    } else if self.deviceMigrationOwner.replacementListState == .unavailable {
                        Section {
                            Text(AppStrings.ios_lookup_migration_list_unavailable_title()).font(.headline)
                            Text(AppStrings.ios_lookup_migration_list_unavailable_body())
                            Button(AppStrings.ios_lookup_migration_list_unavailable_action()) {
                                Task { await self.deviceMigrationOwner.loadReplacementClients() }
                            }
                        }
                    } else {
                        ForEach(self.deviceMigrationOwner.replacementRows, id: \.client.cid) { row in
                            Button {
                                self.deviceMigrationOwner.selectedCID = row.client.cid
                                guard let presentation = self.deviceMigrationOwner.freshReplacementPresentation(targetCID: row.client.cid) else { return }
                                self.replacementPresentation = presentation
                                self.pendingReplacementCID = row.client.cid
                                self.pendingReplacementLabel = row.client.displayLabel
                            } label: {
                                LabeledContent(row.label, value: row.client.cid)
                            }
                        }
                    }
                }
                .navigationTitle(AppStrings.ios_lookup_migration_picker_title())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppStrings.ios_lookup_migration_picker_cancel()) { self.showingFreshPairOffer = false }
                    }
                }
            }
            .confirmationDialog(
                Text(verbatim: self.localizedMigrationCopy(
                    "migration.replace_confirm.title",
                    selectedDeviceLabel: self.pendingReplacementLabel
                )),
                isPresented: Binding(
                    get: { self.pendingReplacementCID != nil },
                    set: {
                        if !$0 {
                            self.pendingReplacementCID = nil
                            self.pendingReplacementLabel = ""
                            self.replacementPresentation = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let presentation = self.replacementPresentation {
                    Button(AppStrings.ios_lookup_migration_replace_confirm_replace(), role: .destructive) {
                        self.pendingReplacementCID = nil
                        self.pendingReplacementLabel = ""
                        self.replacementPresentation = nil
                        self.showingFreshPairOffer = false
                        Task { await self.deviceMigrationOwner.confirmFreshPairReplacement(presentedContext: presentation) }
                    }
                }
                Button(AppStrings.ios_lookup_migration_replace_confirm_cancel(), role: .cancel) {
                    self.pendingReplacementCID = nil
                    self.pendingReplacementLabel = ""
                    self.replacementPresentation = nil
                }
            } message: {
                Text(verbatim: self.localizedMigrationCopy(
                    "migration.replace_confirm.body",
                    selectedDeviceLabel: self.pendingReplacementLabel
                ))
            }
        }
        .sheet(isPresented: self.$showingPairFlow) {
            NavigationStack {
                PairFlowView(
                    onBack: { self.showingPairFlow = false },
                    onComplete: { self.showingPairFlow = false }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppStrings.ios_migration_picker_cancel()) { self.showingPairFlow = false }
                    }
                }
            }
        }
        .confirmationDialog(
            Text(AppStrings.ios_lookup_migration_choice_title()),
            isPresented: self.$showingSameDeviceConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppStrings.ios_lookup_migration_choice_same(), role: .destructive) {
                guard let context = self.sameDevicePresentation else { return }
                Task { await self.deviceMigrationOwner.submitMigrationChoice(.sameDevice, presentedContext: context) }
            }
            Button(AppStrings.ios_lookup_migration_choice_new()) {
                guard let context = self.sameDevicePresentation else { return }
                Task { await self.deviceMigrationOwner.submitMigrationChoice(.newDevice, presentedContext: context) }
            }
            Button(AppStrings.ios_lookup_migration_choice_defer(), role: .cancel) {
                self.deviceMigrationOwner.deferMigrationChoice()
            }
        } message: {
            Text(AppStrings.ios_lookup_migration_choice_body_fallback())
        }

    }

    private func localizedMigrationCopy(_ key: String, selectedDeviceLabel: String) -> String {
        if key == "migration.replace_confirm.title", selectedDeviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppStrings.legacy("migration.replace_confirm.title_fallback")
        }
        return AppStrings.legacy(key, values: ["selected_device_label": selectedDeviceLabel])
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
        content.alert(AppStrings.ios_home_body62(), isPresented: self.$isPresented) {
            Button(AppStrings.ios_migration_picker_cancel(), role: .cancel) {}
            Button(AppStrings.ios_home_body61(), role: .destructive) {
                Task {
                    await self.unpair()
                }
            }
        } message: {
            Text(SourceVocabulary.waitingGoesToNextJournal)
        }
    }

    private func unpair() async {
        await unpairThisDevice(
            appConfig: self.appConfig,
            onboardingFlow: self.onboardingFlow,
            tunnelManager: self.tunnelManager
        )
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
    @Environment(WatchLink.self) private var watchLink
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var copyResult: String?

    private var version: String {
        AppVersion.shortVersion
    }

    private var build: String {
        AppVersion.build
    }

    private var server: String {
        self.appConfig.journalVersion.displayValue
    }

    private var device: String {
        DeviceRegistrationDescriptor.currentDisplayName()
    }

    private var journalRoot: String {
        self.appConfig.journalRoot.isEmpty ? AppStrings.ios_shelfpane_unpaired() : self.appConfig.journalRoot
    }

    var body: some View {
        let aboutBlock = PhoneAboutBlock.block(
            journalVersion: self.appConfig.journalVersion,
            watchFacts: self.watchLink.aboutWatchFacts
        )
        GeometryReader { proxy in
            List {
                Section {
                    VStack(spacing: 16) {
                        Image("SolWordmark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120)

                        Text(AppStrings.ios_home_body59())
                            .font(.custom("Comfortaa-Bold", size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, max(proxy.size.height * 0.08, 32))
                }
                .listRowBackground(Color.clear)

                Section {
                    LabeledContent(AppStrings.ios_home_body63(), value: self.version)
                    LabeledContent(AppStrings.ios_home_body5(), value: self.build)
                    LabeledContent(AppStrings.ios_home_body16(), value: self.server)
                    LabeledContent(AppStrings.ios_home_body9(), value: self.device)
                    LabeledContent(AppStrings.ios_home_body15(), value: self.journalRoot)
                }

                Section {
                    NavigationLink(value: ShellDestination.licenses) {
                        Text(AppStrings.ios_lookup_about_licenses())
                    }
                    .accessibilityIdentifier("shell.pane.shelfAbout.licenses")
                    .hoverEffect(.highlight)
                }

                Section(AppStrings.ios_home_body3()) {
                    Text(aboutBlock)
                        .textSelection(.enabled)
                    Button(AppStrings.ios_home_body7()) {
                        UIPasteboard.general.string = aboutBlock
                        self.copyResult = UIPasteboard.general.string == aboutBlock
                            ? AppStrings.ios_diagnostics_copied()
                            : AppStrings.ios_home_body8()
                    }
                    if let copyResult = self.copyResult {
                        Text(copyResult)
                    }
                }
            }
        }
        .navigationTitle(ShellDestination.shelfAbout.shelfTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: aboutBlock) { _, _ in self.copyResult = nil }
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
