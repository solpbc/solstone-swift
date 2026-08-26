// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")

struct RootShellView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(ObserverManager.self) private var observerManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(PendingNotificationRouteState.self) private var pendingRoute
    @Environment(PendingJournalOpenState.self) private var pendingJournalOpen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ShellNavModel.self) private var nav
    @Environment(ShellStatusContext.self) private var shellStatusContext
    @Namespace private var homeChrome
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var showingJournalLives = false
    @State private var presentedPane: PresentedShellPane?
    @State private var journalMark: JournalMark?
    @State private var statusPath = NavigationPath()
    @State private var statusDetent: PresentationDetent = .medium
    @State private var showingSources = false
    @State private var observerSourcePauseState = ObserverSourcePauseState()
    @State private var crossFadePreference = AccessibilityCrossFadePreference()

    private var prefersCrossFade: Bool { self.crossFadePreference.prefersCrossFadeTransitions }

    /// The shell with the shelf layered over it. Kept separate from `body` so
    /// neither expression grows past what the type-checker will take.
    private var shellLayers: some View {
        ZStack {
            self.shellBehindShelf

            if self.presentedPane == .shelf {
                ShelfPane(
                    presentation: .phoneModal,
                    onOpenJournal: { self.presentedPane = .journal },
                    onDismiss: { self.presentedPane = nil }
                )
                    .transition(self.prefersCrossFade ? .opacity : .move(edge: .leading))
            }
        }
        .animation(self.prefersCrossFade ? .easeInOut : .default, value: self.presentedPane)
        .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(self.observerSourcePauseState)
        .task {
            await self.crossFadePreference.observe()
        }
    }

    /// The phone shell's four presentations. Split from `body` for the same reason
    /// as `shellLayers`: one chain of this length does not type-check.
    private var shellWithSheets: some View {
        self.shellLayers
        .sheet(isPresented: self.isJournalPresented) {
            InAppJournalView(mark: self.journalMark, presentation: .phoneModal)
                // 0.75 keeps the first deck tile row in the band above the pane on iPhone 17 Pro.
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
                .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .sheet(isPresented: self.$showingSources) {
            SourcesView()
                .environment(self.observerSourcePauseState)
        }
        .sheet(isPresented: self.$showingJournalLives) {
            JournalLivesSheet(isPresented: self.$showingJournalLives)
        }
        .sheet(isPresented: self.isStatusPresented) {
            self.statusSheet
        }
    }

    var body: some View {
        self.shellWithSheets
        .task(id: self.tunnelManager.activeConnection?.port) {
            await self.fetchJournalMark()
        }
        .onAppear {
            if let route = self.pendingRoute.route {
                self.apply(route)
            }
            self.applyPendingJournalOpenIfNeeded()
            if !self.tunnelManager.state.isConnected {
                mainTabLog.info("showing disconnected shell state")
            }
            self.applyDebugSeeds()
        }
        .onChange(of: self.tunnelManager.state.isConnected) { wasConnected, isConnected in
            if !wasConnected && isConnected {
                self.shellStatusContext.connectedSince = Date()
                if let route = self.pendingRoute.route {
                    self.apply(route)
                }
            } else if !isConnected {
                mainTabLog.info("showing disconnected shell state")
            }
        }
        .onChange(of: self.pendingRoute.route) { _, route in
            if let route {
                self.apply(route)
            }
        }
        .onChange(of: self.pendingJournalOpen.isOpenRequested) { _, _ in
            self.applyPendingJournalOpenIfNeeded()
        }
        .onChange(of: self.statusPath.count) { _, count in
            self.statusDetent = count > 0 ? .large : .medium
        }
        .onChange(of: self.presentedPane) { _, pane in
            if pane != .status {
                self.statusPath = NavigationPath()
                self.statusDetent = .medium
            }
        }
    }

    /// The shell, with the deck taken out of the accessibility tree while the
    /// shelf covers it.
    @ViewBuilder
    private var shellBehindShelf: some View {
        if self.presentedPane == .shelf {
            self.splitShell
                .accessibilityHidden(true)
                .accessibilityChildren { EmptyView() }
        } else {
            self.splitShell
        }
    }

    /// The shell.
    ///
    /// The shape decision keys on size class ABOVE the split. At regular width the
    /// deck is permanently the leading column of a two-column split. Collapsed,
    /// the shell is the phone's single stack: a `NavigationSplitView` only pushes
    /// its detail from a selection-driven sidebar, and the deck is a grid of
    /// controls rather than a selection list, so a collapsed split strands every
    /// deck tap. Both shapes read the same two channels, so neither the pane root
    /// nor the pane stack is disturbed by crossing between them.
    /// Type-erased deliberately. The two shapes are large, unrelated view types,
    /// and carrying both through every modifier in `body` is what the type-checker
    /// gives up on. Crossing between them is a genuine shell change, so a fresh
    /// identity here is right rather than merely tolerable.
    private var splitShell: AnyView {
        self.isPhoneShell ? AnyView(self.phoneStack) : AnyView(self.padSplit)
    }

    /// Whether the shell is the phone's single stack rather than the split.
    ///
    /// Compact width, or a pinned deck column that cannot hold two tiles. The deck
    /// is never degenerated to one column inside a split: at an accessibility text
    /// size, and past the text size the column band was derived for, the split
    /// collapses and the shell behaves as compact.
    private var isPhoneShell: Bool {
        if self.horizontalSizeClass != .regular {
            return true
        }
        return splitCollapses(dynamicTypeSize: self.dynamicTypeSize)
    }

    private var padSplit: some View {
        @Bindable var nav = self.nav
        return NavigationSplitView(
            columnVisibility: $nav.columnVisibility,
            preferredCompactColumn: self.$preferredCompactColumn
        ) {
            self.deckColumn
                .navigationSplitViewColumnWidth(
                    min: DeckMetrics.columnMinimum,
                    ideal: DeckMetrics.columnIdeal,
                    max: DeckMetrics.columnMaximum
                )
        } detail: {
            self.paneColumn
        }
        .navigationSplitViewStyle(.balanced)
#if DEBUG
        .overlay(alignment: .topLeading) {
            if self.showsColumnVisibilityProbe {
                Text("")
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(self.columnVisibilityProbeIdentifier)
                    .id(self.columnVisibilityProbeIdentifier)
            }
        }
#endif
    }

#if DEBUG
    private var showsColumnVisibilityProbe: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test")
    }

    private var columnVisibilityProbeIdentifier: String {
        if self.nav.columnVisibility == .all {
            "shell.columnVisibility.all"
        } else if self.nav.columnVisibility == .detailOnly {
            "shell.columnVisibility.detailOnly"
        } else {
            "shell.columnVisibility.unknown"
        }
    }
#endif

    /// The collapsed shell. One stack whose path is the two channels laid end to
    /// end, so a deck tap pushes and a back navigation returns to the deck.
    private var phoneStack: some View {
        NavigationStack(path: self.phonePath) {
            self.deckColumn
                .navigationDestination(for: ShellDestination.self) { destination in
                    ShellDestinationView(destination: destination, journalMark: self.journalMark)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `paneRoot` followed by `paneStack`. Writing a shorter path back pops, and
    /// popping all the way clears the deck's selection.
    private var phonePath: Binding<[ShellDestination]> {
        Binding(
            get: {
                guard let root = self.nav.paneRoot else { return [] }
                return [root] + self.nav.paneStack
            },
            set: { path in
                guard let root = path.first else {
                    self.nav.selectFromDeck(nil)
                    return
                }
                if root == self.nav.paneRoot {
                    self.nav.paneStack = Array(path.dropFirst())
                } else {
                    self.nav.selectFromDeck(root)
                }
            }
        )
    }

    private var deckColumn: some View {
        DayHomeView(
            journalState: self.dayHomeJournalState,
            journalMark: self.journalMark,
            homeChrome: self.homeChrome,
            onOpenJournal: { self.openJournal() },
            onOpenJournalSetup: { self.openJournalSetup() },
            onOpenSources: { self.openSources() },
            onOpenYourSolstone: { self.openYourSolstone() },
            onOpenStatus: { self.openStatus() },
            sourcesBadgeVisible: self.sourcesBadgeVisible
        )
        .overlay(alignment: .leading) {
            if self.isPhoneShellAtRest {
                ShelfHitStrip(onOpen: { self.openYourSolstone() })
            }
        }
    }

    /// The pane. Its stack carries the push channel and owns the detail column's
    /// `ShellDestination` registration, so a link inside the pane pushes while a
    /// tap in the deck replaces.
    private var paneColumn: some View {
        @Bindable var nav = self.nav
        return NavigationStack(path: $nav.paneStack) {
            ShellDestinationView(
                destination: self.paneRootDestination,
                journalMark: self.journalMark
            )
                .navigationDestination(for: ShellDestination.self) { destination in
                    ShellDestinationView(destination: destination, journalMark: self.journalMark)
                }
        }
    }

    /// What the pane shows at its root: the deck's selection, or the computed
    /// default when the owner has not chosen yet.
    private var paneRootDestination: ShellDestination {
        self.nav.resolvedPaneRoot(isPaired: self.appConfig.isPaired)
    }

    /// The edge gestures and the hit strip belong to the phone shell only: on
    /// iPad the leading edge is the system sidebar swipe and the top edge is the
    /// menu bar.
    private var isPhoneShellAtRest: Bool {
        self.isPhoneShell && self.nav.paneRoot == nil && self.nav.paneStack.isEmpty
    }

    /// The four fixed openers, plus the journal-setup door.
    ///
    /// The shape decision sits here, above the split: at regular width each one
    /// replaces the pane root; collapsed, each one keeps the phone shell's own
    /// presentation. `applyDebugSeeds()` routes through these same methods so the
    /// seed and the real opener cannot drift.
    private func openJournal() {
        if self.isPhoneShell {
            self.presentedPane = .journal
        } else {
            self.nav.selectFromDeck(.journal)
        }
    }

    private func applyPendingJournalOpenIfNeeded() {
        guard self.pendingJournalOpen.isOpenRequested else { return }
        self.pendingJournalOpen.isOpenRequested = false
        self.openJournal()
    }

    private func openJournalSetup() {
        if self.isPhoneShell {
            self.showingJournalLives = true
        } else {
            self.nav.selectFromDeck(.journalSetup)
        }
    }

    private func openSources() {
        if self.isPhoneShell {
            self.showingSources = true
        } else {
            self.nav.selectFromDeck(.addMore)
        }
    }

    private func openYourSolstone() {
        if self.isPhoneShell {
            self.presentedPane = .shelf
        } else {
            self.nav.selectFromDeck(.shelf)
        }
    }

    private func openStatus() {
        if self.isPhoneShell {
            self.presentedPane = .status
        } else {
            self.nav.selectFromDeck(.status)
        }
    }

    private var isJournalPresented: Binding<Bool> {
        Binding(
            get: { self.presentedPane == .journal },
            set: { if !$0, self.presentedPane == .journal { self.presentedPane = nil } }
        )
    }

    private var isStatusPresented: Binding<Bool> {
        Binding(
            get: { self.presentedPane == .status },
            set: { if !$0, self.presentedPane == .status { self.presentedPane = nil } }
        )
    }

    @ViewBuilder
    private var statusSheet: some View {
        NavigationStack(path: self.$statusPath) {
            Group {
                if self.reduceMotion || self.prefersCrossFade {
                    StatusPane(presentation: .phoneModal)
                } else {
                    StatusPane(presentation: .phoneModal)
                        .navigationTransition(.zoom(sourceID: HomeChromeID.status, in: self.homeChrome))
                }
            }
            .navigationDestination(for: ShellDestination.self) { destination in
                ShellDestinationView(destination: destination, journalMark: self.journalMark)
            }
        }
        .presentationDetents([.medium, .large], selection: self.$statusDetent)
        .presentationDragIndicator(.visible)
        .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fetchJournalMark() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-journal-mark"),
           !ProcessInfo.processInfo.arguments.contains("--ui-test-no-journal")
        {
            return
        }
#endif
        guard let port = self.tunnelManager.activeConnection?.port else {
            self.journalMark = nil
            return
        }
        self.journalMark = await JournalIdentityFetcher().fetch(localPort: port)
    }

    private func applyDebugSeeds() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test") else { return }
        if arguments.contains("--ui-test-journal-mark"),
           !arguments.contains("--ui-test-no-journal")
        {
            self.journalMark = .uiTestSample
        }
        if let raw = arguments.first(where: { $0.hasPrefix("--ui-test-open-pane=") }) {
            let pane = String(raw.dropFirst("--ui-test-open-pane=".count))
            switch pane {
            case "status":
                self.openStatus()
            case "journal":
                self.openJournal()
            case "shelf":
                self.openYourSolstone()
            default:
                break
            }
        }
#endif
    }

    private var sourcesBadgeVisible: Bool {
        [
            sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused),
            self.locationManager.sourceState,
            screencastSourceState(for: self.screencastManager.state),
        ].contains(where: \.showsSourcesBadge)
    }

    // Inline switch is pinned by ConnectionSyncGrepTests:9-14 and
    // IntegrationGateG4G5ConnectionSyncTests:176-186. Do not replace with
    // dayHomeJournalState(isPaired:status:).
    private var dayHomeJournalState: DayHomeJournalState {
        if !self.appConfig.isPaired {
            return .noJournal
        }
        switch self.connectionSyncModel.status {
        case .connectedIdle, .connectedWaiting, .connectedTransferring:
            return .linkedOnline
        case .offline, .connecting, .waitingForHome, .reconnecting, .unreachable:
            return .linkedOffline
        }
    }

    private func apply(_ route: NotificationRoute) {
        self.showingSources = false
        self.showingJournalLives = false
        self.presentedPane = nil
        switch route {
        case .today:
            break
        case .sources:
            self.showingSources = true
        case .observerActivityRearm:
            Task { @MainActor in
                await self.observerManager.rearmLiveActivity()
            }
        }
        self.pendingRoute.route = nil
    }
}

private extension SourceState {
    var showsSourcesBadge: Bool {
        switch self {
        case .enrolling, .active, .needsAttention:
            true
        case .off, .readyToSetUp, .checking, .paused:
            false
        }
    }
}

private struct ShelfHitStrip: View {
    let onOpen: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.width > 40 {
                            self.onOpen()
                        }
                    }
            )
            .accessibilityHidden(true)
            .accessibilityIdentifier("shell.hitStrip")
    }
}

@Observable
final class AccessibilityCrossFadePreference {
    private(set) var prefersCrossFadeTransitions = UIAccessibility.prefersCrossFadeTransitions

    func observe() async {
        self.prefersCrossFadeTransitions = UIAccessibility.prefersCrossFadeTransitions
        let notifications = NotificationCenter.default.notifications(
            named: UIAccessibility.prefersCrossFadeTransitionsStatusDidChange
        )
        for await _ in notifications {
            self.prefersCrossFadeTransitions = UIAccessibility.prefersCrossFadeTransitions
        }
    }
}
