// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")

/// Geometry around the status content, plus whether that content is showing.
/// A change of size class, orientation, text size, or split columns is not the content hiding.
struct JournalGapSurfaceTransition: Equatable {
    var horizontalSizeClass: UserInterfaceSizeClass?
    var verticalSizeClass: UserInterfaceSizeClass?
    var dynamicTypeSize: DynamicTypeSize
    var columnVisibility: NavigationSplitViewVisibility
    var surfaceVisible: Bool
}

/// A write through the collapsed shell's path.
enum CollapsedPhonePathUpdate: Equatable {
    case ignore
    case select(ShellDestination?)
    case setStack([ShellDestination])
    case pinDefaultAndSetStack([ShellDestination])
}

/// What a geometry change does to the visit.
enum JournalGapSurfaceEffect: Equatable {
    /// The content is still showing, or a carry keeps it showing.
    case keep(JournalGapSurfaceCarry?)
    case capture
    case end
}

/// How a layout change keeps the losses on screen.
enum JournalGapSurfaceCarry: Equatable {
    /// The collapsed shell would show the deck. Present the status sheet.
    case presentStatusSheet
    /// A push was showing on the default pane. Pin that root so the collapsed stack shows it.
    case showPushedStack
    /// The split detail is the status content. Drop the phone sheet that would cover it.
    case dismissStatusSheet
}

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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ShellNavModel.self) private var nav
    @Environment(ShellStatusContext.self) private var shellStatusContext
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var homeChrome
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var showingJournalLives = false
    @State private var presentedPane: PresentedShellPane?
    @State private var journalInitialPath: String = "/"
    /// Seeded from the store so the owner's own mark is on screen in the **first frame**,
    /// before any tunnel exists. See `JournalMarkStore` for why this is an absolute.
    @State private var journalMark: JournalMark? = RootShellView.storedJournalMark()
    @ObservationIgnored private let journalMarkStore = JournalMarkStore()
    @State private var statusPath = NavigationPath()
    @State private var statusDetent: PresentationDetent = .medium
    /// Owned here so rotation does not drop the visit. It ends when the content hides or the scene leaves active.
    @State private var journalGapVisit = JournalGapVisit()
    @State private var showingSources = false
    @State private var observerSourcePauseState = ObserverSourcePauseState()
    @State private var crossFadePreference = AccessibilityCrossFadePreference()
    /// Measured rather than read from a `GeometryReader`: wrapping the whole shell in
    /// one disturbed layout and presentation across surfaces that have nothing to do
    /// with the shelf.
    @State private var shellWidth: CGFloat = 0
#if DEBUG
    @State private var sunArcDebugOverride: SunArcBackgroundDebugOverride?
#endif

    private var prefersCrossFade: Bool { self.crossFadePreference.prefersCrossFadeTransitions }

    /// Whether the shelf takes the whole window instead of being a drawer.
    ///
    /// A landscape phone has no room for a panel *and* a legible strip of shell, so the
    /// shelf covers everything — which also means there is no dimmed shell to tap, and
    /// the panel keeps an explicit close control in that case alone.
    private var shelfFillsWindow: Bool { self.verticalSizeClass == .compact }

    /// The shell with the shelf beside it.
    ///
    /// As a drawer the shelf **pushes**: the shell translates right by exactly the
    /// panel's width and carries a dimming scrim with it, so the owner watches their own
    /// content move aside and can see where tapping returns them.
    ///
    /// ⚠ **The previous build layered the panel over the shell and the shell was not
    /// there at all.** `shellBehindShelf` carried `.accessibilityChildren { EmptyView() }`,
    /// which removes a subtree from the RENDER tree and not merely the accessibility
    /// tree. Measured on a screenshot, the exposed strip was a flat, uniform
    /// `(194,194,194)` — 24% black over *white*, not over the cream deck. The trailing
    /// band was always meant to show the deck (`PaneHostUITests` AC2 says so in as many
    /// words); it never did.
    private var shellLayers: some View {
        let isOpen = self.presentedPane == .shelf
        let fillsWindow = self.shelfFillsWindow
        let panelWidth = fillsWindow
            ? self.shellWidth
            : ShelfMetrics.panelWidth(containerWidth: self.shellWidth)
        // ⚠ An owner who prefers cross-fade gets no translation at all: the shell stays
        // put and the panel fades in over it. Re-easing a slide is not a cross-fade.
        let pushes = isOpen && !fillsWindow && !self.prefersCrossFade

        return ZStack(alignment: .leading) {
            self.shellBehindShelf
                .environment(\.sunArcCovered, isOpen && fillsWindow)
                // The scrim rides ON the shell, so it translates with it.
                .overlay {
                    Color.black
                        .opacity(isOpen && !fillsWindow ? ShelfMetrics.scrimOpacity : 0)
                        .ignoresSafeArea()
                        .allowsHitTesting(isOpen && !fillsWindow)
                        .onTapGesture { self.presentedPane = nil }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(SourceVocabulary.shelfDismissLabel)
                        .accessibilityHidden(!isOpen || fillsWindow)
                }
                .offset(x: pushes ? panelWidth : 0)

            if isOpen {
                ShelfPane(
                    presentation: .phoneModal,
                    journalMark: self.journalMark,
                    onOpenJournal: { self.presentedPane = .journal },
                    onDismiss: { self.presentedPane = nil }
                )
                .frame(width: fillsWindow ? nil : panelWidth)
                .frame(maxWidth: fillsWindow ? .infinity : nil)
                .transition(
                    self.prefersCrossFade ? .opacity : .move(edge: .leading)
                )
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { self.shellWidth = $0 }
        .animation(
            self.prefersCrossFade ? .easeInOut(duration: ShelfMetrics.openDuration)
                                  : .easeOut(duration: ShelfMetrics.openDuration),
            value: self.presentedPane
        )
        .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            await self.crossFadePreference.observe()
        }
    }

    /// The phone shell's four presentations. Split from `body` for the same reason
    /// as `shellLayers`: one chain of this length does not type-check.
    private var shellWithSheets: some View {
        self.shellLayers
        .sheet(isPresented: self.isJournalPresented) {
            InAppJournalView(mark: self.journalMark, presentation: .phoneModal, path: self.journalInitialPath)
                // Full height — the largest system detent, so the pane's top reaches
                // the top of the screen instead of leaving the deck readable above it.
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .sheet(isPresented: self.$showingSources) {
            SourcesView()
        }
        .sheet(isPresented: self.$showingJournalLives) {
            JournalLivesSheet(isPresented: self.$showingJournalLives)
        }
        .sheet(isPresented: self.isStatusPresented) {
            self.statusSheet
        }
    }

    private var sunArcShell: some View {
#if DEBUG
        SunArcBackgroundHost(
            palette: DeckSunArcPalette.value,
            presentationCoordinate: self.locationManager.sunArcPresentationCoordinate,
            debugOverride: self.sunArcDebugOverride,
            rootCovered: self.presentedPane == .shelf && self.shelfFillsWindow
        ) {
            self.shellWithSheets
        }
#else
        SunArcBackgroundHost(
            palette: DeckSunArcPalette.value,
            presentationCoordinate: self.locationManager.sunArcPresentationCoordinate,
            rootCovered: self.presentedPane == .shelf && self.shelfFillsWindow
        ) {
            self.shellWithSheets
        }
#endif
    }

    var body: some View {
        self.sunArcShell
        .modifier(DeviceMigrationInitialPrompt())
        // Injected here, above every sheet and presentation the shell declares, so a
        // source screen opened from inside one of them finds it too. Injected lower,
        // the status sheet's audio screen could not find it and the app stopped.
        .environment(self.observerSourcePauseState)
        .environment(self.journalGapVisit)
        .task(id: self.tunnelManager.activeConnection?.port) {
            await self.fetchJournalMark()
        }
        .onChange(of: self.appConfig.deviceID) { priorInstanceID, currentInstanceID in
            self.journalChanged(from: priorInstanceID, to: currentInstanceID)
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
            Task { await self.captureJournalGapIfVisible() }
        }
        .onChange(of: self.journalGapSurfaceTransition) { prior, next in
            self.applyJournalGapSurfaceChange(from: prior, to: next)
        }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase == .active else {
                self.journalGapVisit.background()
                return
            }
            Task { await self.beginJournalGapVisit() }
        }
        .onChange(of: self.appConfig.journalIdentityEpoch) { _, _ in
            self.mobileSegmentTransferHolder.refreshJournalGap()
        }
        .task(id: self.scenePhase) {
            await self.recomputeJournalGapAtDayBoundary()
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
                if !self.journalGapSurfaceVisible {
                    self.journalGapVisit.end()
                }
            }
        }
    }

    /// The shell, with the deck taken out of the accessibility tree while the
    /// shelf is open.
    ///
    /// 🔴 **This carried `.accessibilityChildren { EmptyView() }` until 2026-09-01, and
    /// that modifier removed the shell from the RENDER tree, not just the accessibility
    /// tree.** So the whole time the shelf was open there was nothing behind it — the
    /// exposed strip beside the panel was the window's own white, dimmed by the scrim,
    /// which is why it read as a dead grey slab rather than as the owner's day.
    /// Measured before: a flat `(194,194,194)` = 24% black over white. After: the deck's
    /// cream `(252,243,228)` and its tile surface, correctly dimmed.
    /// ⛔ Do not reintroduce it — `.accessibilityHidden(true)` alone takes the subtree
    /// out of the accessibility tree, which is all that was wanted.
    @ViewBuilder
    private var shellBehindShelf: some View {
        if self.presentedPane == .shelf {
            self.splitShell
                // ⛔ NOT `.accessibilityChildren { EmptyView() }` — that is what used to
                // be here, and it removes the subtree from the RENDER tree too, which is
                // why nothing was ever behind the drawer. `children: .ignore` collapses
                // the shell to one element and `accessibilityHidden` hides that element,
                // with no effect on what is drawn.
                .accessibilityElement(children: .ignore)
                .accessibilityHidden(true)
                // ⚠ Neither reaches the shell's TOOLBAR: SwiftUI hoists toolbar content
                // out of the subtree and into the navigation bar, so the deck's own
                // shelf control stayed reachable behind the open drawer — by VoiceOver,
                // and by a UI test's `navigationBars.buttons.firstMatch`, which tapped it
                // and closed the drawer instead of going back. The scrim blocks touches;
                // it cannot block the accessibility tree.
                .toolbar(.hidden, for: .navigationBar)
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
        Self.shellIsPhone(horizontalSizeClass: self.horizontalSizeClass, dynamicTypeSize: self.dynamicTypeSize)
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
                // ⚠ Hidden from assistive tech HERE, inside the stack, not outside it.
                // A `NavigationStack` hosts its content separately, so an
                // `.accessibilityHidden` applied to the stack from outside does not
                // reach the deck — which is why this once used
                // `.accessibilityChildren { EmptyView() }`, the modifier that also
                // stopped the shell rendering. Applied to the content it simply works.
                .accessibilityHidden(self.presentedPane == .shelf)
                .navigationDestination(for: ShellDestination.self) { destination in
                    ShellDestinationView(
                        destination: destination,
                        journalMark: self.journalMark,
                        journalPath: self.journalInitialPath
                    )
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `paneRoot` followed by `paneStack`. A nil root with a push still shows that
    /// push: the collapsed shell would otherwise drop it and the gap would leave the screen.
    /// Writing a shorter path back pops, and popping all the way clears the deck's selection.
    private var phonePath: Binding<[ShellDestination]> {
        Binding(
            get: {
                Self.collapsedPhoneDestinations(
                    paneRoot: self.nav.paneRoot,
                    paneStack: self.nav.paneStack,
                    resolvedRoot: self.nav.resolvedPaneRoot(isPaired: self.appConfig.isPaired)
                )
            },
            set: { path in
                let resolved = self.nav.resolvedPaneRoot(isPaired: self.appConfig.isPaired)
                switch Self.collapsedPhonePathUpdate(
                    paneRoot: self.nav.paneRoot,
                    paneStack: self.nav.paneStack,
                    resolvedRoot: resolved,
                    written: path
                ) {
                case .ignore:
                    break
                case .select(let destination):
                    self.nav.selectFromDeck(destination)
                case .setStack(let stack):
                    self.nav.paneStack = stack
                case .pinDefaultAndSetStack(let stack):
                    self.nav.adoptDefaultRoot(isPaired: self.appConfig.isPaired)
                    self.nav.paneStack = stack
                }
            }
        )
    }

    /// The collapsed stack's path. A nil root shows nothing until there is a push to keep.
    static func collapsedPhoneDestinations(
        paneRoot: ShellDestination?,
        paneStack: [ShellDestination],
        resolvedRoot: ShellDestination
    ) -> [ShellDestination] {
        if let paneRoot {
            return [paneRoot] + paneStack
        }
        guard !paneStack.isEmpty else { return [] }
        return [resolvedRoot] + paneStack
    }

    /// What a write to the collapsed path means. An echo of a synthesized path is ignored
    /// so the stack is not cleared when the shell collapses.
    static func collapsedPhonePathUpdate(
        paneRoot: ShellDestination?,
        paneStack: [ShellDestination],
        resolvedRoot: ShellDestination,
        written: [ShellDestination]
    ) -> CollapsedPhonePathUpdate {
        if paneRoot == nil {
            let synthesized = Self.collapsedPhoneDestinations(
                paneRoot: nil,
                paneStack: paneStack,
                resolvedRoot: resolvedRoot
            )
            if written == synthesized {
                return .ignore
            }
            if written.first == resolvedRoot {
                return .pinDefaultAndSetStack(Array(written.dropFirst()))
            }
        }
        guard let root = written.first else {
            return .select(nil)
        }
        if root == paneRoot {
            return .setStack(Array(written.dropFirst()))
        }
        return .select(root)
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
                journalMark: self.journalMark,
                journalPath: self.journalInitialPath
            )
                .navigationDestination(for: ShellDestination.self) { destination in
                    ShellDestinationView(
                        destination: destination,
                        journalMark: self.journalMark,
                        journalPath: self.journalInitialPath
                    )
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
    private func openJournal(path: String = "/") {
        self.journalInitialPath = path
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
        if Self.journalGapVisitMayStart(
            sceneIsActive: self.scenePhase == .active,
            surfaceVisible: self.journalGapSurfaceVisible
        ) {
            Task { await self.beginJournalGapVisit() }
        }
        if self.isPhoneShell {
            self.presentedPane = .status
        } else {
            self.nav.selectFromDeck(.status)
        }
    }

    /// A visit starts only while the scene is active and the status content is showing.
    static func journalGapVisitMayStart(sceneIsActive: Bool, surfaceVisible: Bool) -> Bool {
        sceneIsActive && surfaceVisible
    }

    /// Rotation, size class, and a split-view resize keep a visit while its content is still showing.
    /// A change that hides that content, and has nothing to carry it, ends the visit.
    static func journalGapKeepsVisit(
        from prior: JournalGapSurfaceTransition,
        to next: JournalGapSurfaceTransition
    ) -> Bool {
        let geometryChanged = prior.horizontalSizeClass != next.horizontalSizeClass
            || prior.verticalSizeClass != next.verticalSizeClass
            || prior.dynamicTypeSize != next.dynamicTypeSize
            || prior.columnVisibility != next.columnVisibility
        if geometryChanged && prior.surfaceVisible {
            return true
        }
        return next.surfaceVisible
    }

    /// The shell shape that hides status content, and the shape that would cover it with a sheet.
    static func journalGapSurfaceCarry(
        from prior: JournalGapSurfaceTransition,
        to next: JournalGapSurfaceTransition,
        paneRootIsNil: Bool,
        paneStackIsEmpty: Bool,
        statusSheetPresented: Bool,
        otherSheetPresented: Bool,
        visitShowsLoss: Bool
    ) -> JournalGapSurfaceCarry? {
        guard self.journalGapKeepsVisit(from: prior, to: next), prior.surfaceVisible else { return nil }
        let wasPhone = Self.shellIsPhone(
            horizontalSizeClass: prior.horizontalSizeClass,
            dynamicTypeSize: prior.dynamicTypeSize
        )
        let isPhone = Self.shellIsPhone(
            horizontalSizeClass: next.horizontalSizeClass,
            dynamicTypeSize: next.dynamicTypeSize
        )
        if !wasPhone && isPhone && !otherSheetPresented {
            if paneRootIsNil && !paneStackIsEmpty {
                return .showPushedStack
            }
            if paneStackIsEmpty && !next.surfaceVisible && !statusSheetPresented && visitShowsLoss {
                return .presentStatusSheet
            }
        }
        if wasPhone && !isPhone && statusSheetPresented && next.surfaceVisible {
            return .dismissStatusSheet
        }
        return nil
    }

    /// A geometry change keeps the visit when the content stays visible or a carry shows it.
    /// Hiding the content with nothing to carry ends the visit, so the next showing is a new one.
    static func journalGapSurfaceEffect(
        from prior: JournalGapSurfaceTransition,
        to next: JournalGapSurfaceTransition,
        paneRootIsNil: Bool,
        paneStackIsEmpty: Bool,
        statusSheetPresented: Bool,
        otherSheetPresented: Bool,
        visitShowsLoss: Bool
    ) -> JournalGapSurfaceEffect {
        if self.journalGapKeepsVisit(from: prior, to: next), prior.surfaceVisible {
            let carry = self.journalGapSurfaceCarry(
                from: prior,
                to: next,
                paneRootIsNil: paneRootIsNil,
                paneStackIsEmpty: paneStackIsEmpty,
                statusSheetPresented: statusSheetPresented,
                otherSheetPresented: otherSheetPresented,
                visitShowsLoss: visitShowsLoss
            )
            if next.surfaceVisible || carry != nil {
                return .keep(carry)
            }
            return .end
        }
        if next.surfaceVisible {
            return .capture
        }
        return .end
    }

    static func shellIsPhone(horizontalSizeClass: UserInterfaceSizeClass?, dynamicTypeSize: DynamicTypeSize) -> Bool {
        if horizontalSizeClass != .regular {
            return true
        }
        return splitCollapses(dynamicTypeSize: dynamicTypeSize)
    }

    private func applyJournalGapSurfaceChange(
        from prior: JournalGapSurfaceTransition,
        to next: JournalGapSurfaceTransition
    ) {
        switch Self.journalGapSurfaceEffect(
            from: prior,
            to: next,
            paneRootIsNil: self.nav.paneRoot == nil,
            paneStackIsEmpty: self.nav.paneStack.isEmpty,
            statusSheetPresented: self.presentedPane == .status,
            otherSheetPresented: self.journalGapOtherSheetPresented,
            visitShowsLoss: self.journalGapVisitShowsLoss
        ) {
        case .keep(let carry):
            switch carry {
            case .presentStatusSheet:
                self.presentedPane = .status
            case .showPushedStack:
                self.nav.adoptDefaultRoot(isPaired: self.appConfig.isPaired)
            case .dismissStatusSheet:
                self.presentedPane = nil
            case nil:
                break
            }
        case .capture:
            Task { await self.captureJournalGapIfVisible() }
        case .end:
            self.journalGapVisit.end()
        }
    }

    private var journalGapVisitShowsLoss: Bool {
        !self.journalGapVisit.displayed(live: self.mobileSegmentTransferHolder.journalGapNotice.losses).isEmpty
    }

    private var journalGapOtherSheetPresented: Bool {
        let paneCovers = self.presentedPane != nil && self.presentedPane != .status
        return paneCovers || self.showingSources || self.showingJournalLives
    }

    private var journalGapSurfaceTransition: JournalGapSurfaceTransition {
        JournalGapSurfaceTransition(
            horizontalSizeClass: self.horizontalSizeClass,
            verticalSizeClass: self.verticalSizeClass,
            dynamicTypeSize: self.dynamicTypeSize,
            columnVisibility: self.nav.columnVisibility,
            surfaceVisible: self.journalGapSurfaceVisible
        )
    }

    /// Phone status is the sheet. iPad status is the detail pane, including the paired default.
    /// A push that covers that content is not a visit. On-this-device is a path value.
    private var journalGapSurfaceVisible: Bool {
        self.statusSurfaceVisible || self.onThisDeviceVisible
    }

    private var statusSurfaceVisible: Bool {
        if self.isPhoneShell {
            return self.presentedPane == .status && self.statusPath.isEmpty
        }
        if self.nav.paneStack.contains(.status) { return true }
        return self.nav.paneStack.isEmpty
            && self.nav.resolvedPaneRoot(isPaired: self.appConfig.isPaired) == .status
    }

    private var onThisDeviceVisible: Bool {
        self.nav.paneStack.contains(.onThisDevice)
    }

    /// Starts a visit when none is underway. A visit already showing does not mark a later loss.
    private func captureJournalGapIfVisible() async {
        await self.requestJournalGapVisit(fresh: false)
    }

    /// The scene became active, or the owner opened status that was already showing.
    private func beginJournalGapVisit() async {
        await self.requestJournalGapVisit(fresh: true)
    }

    private func requestJournalGapVisit(fresh: Bool) async {
        await self.journalGapVisit.requestStart(
            fresh: fresh,
            isShowing: {
                Self.journalGapVisitMayStart(
                    sceneIsActive: self.scenePhase == .active,
                    surfaceVisible: self.journalGapSurfaceVisible
                )
            },
            refresh: { await self.mobileSegmentTransferHolder.refreshJournalGapNotice() },
            live: { self.mobileSegmentTransferHolder.journalGapNotice.losses },
            store: self.mobileSegmentTransferHolder.journalEvents
        )
        self.mobileSegmentTransferHolder.refreshJournalGap()
    }

    private func recomputeJournalGapAtDayBoundary() async {
        while !Task.isCancelled {
            guard self.scenePhase == .active else { return }
            let delay = JournalGapNotice.delayUntilNextDay(from: Date())
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, self.scenePhase == .active else { return }
            await self.mobileSegmentTransferHolder.refreshJournalGapNotice()
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
                ShellDestinationView(
                    destination: destination,
                    journalMark: self.journalMark,
                    journalPath: self.journalInitialPath
                )
            }
        }
        .presentationDetents([.medium, .large], selection: self.$statusDetent)
        .presentationDragIndicator(.visible)
        .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The stored mark, suppressed under UI test so seeded fixtures stay authoritative.
    ///
    /// ⚠ Without the guard a mark persisted by an earlier run would leak into
    /// `--ui-test-no-journal`, which asserts the *generic* mark renders.
    static func storedJournalMark() -> JournalMark? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test") { return nil }
#endif
        return JournalMarkStore().load()
    }

    /// Renders the stored mark immediately, then refreshes it from the journal when a tunnel
    /// is up.
    ///
    /// ⛔ **A failed or absent connection never blanks the mark.** It used to: this ran on
    /// `activeConnection?.port` changing, and the no-port branch assigned `nil`, so every
    /// launch and every dropped tunnel dropped the shell back to the generic mark until sync
    /// came up. The mark belongs to the *pairing*, not the connection — once this device is
    /// paired it is an absolute, and the only thing that clears it is unpairing.
    private func fetchJournalMark() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-journal-mark"),
           !ProcessInfo.processInfo.arguments.contains("--ui-test-no-journal")
        {
            return
        }
#endif
        if self.journalMark == nil {
            self.journalMark = Self.storedJournalMark()
        }
        guard let port = self.tunnelManager.activeConnection?.port else { return }
        // With no mark known (a reinstall keeps the pairing but not the mark), ask a few more
        // times over the first ~45 seconds of this connection: one short read at connect time is
        // easy to miss. The task is keyed on the port, so a new connection starts over. Until
        // then a reinstall shows unavailable via select (confirmed pairing with nil mark).
        for delay in [0, 2, 5, 10, 30] as [UInt64] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            let expectedInstanceID = self.appConfig.loadStoredPairing()?.instanceID
            if case .match(let fetched) = await JournalIdentityFetcher().fetch(localPort: port, expectedInstanceID: expectedInstanceID) {
                guard !Task.isCancelled else { return }
                self.journalMark = fetched
                self.journalMarkStore.save(fetched)
                return
            }
            if self.journalMark != nil { return }
        }
    }

    /// Pairing a different journal in place of this one ends the old pairing without an unpair,
    /// so the old journal's mark goes with it here; forgetting has already cleared the store.
    /// A first pairing (from no journal) changes nothing here: there was no old mark to drop.
    private func journalChanged(from priorInstanceID: String, to currentInstanceID: String) {
#if DEBUG
        // UI-test seeding rewrites the device id on every launch; it is not a new journal.
        if ProcessInfo.processInfo.arguments.contains("--ui-test") { return }
#endif
        guard !priorInstanceID.isEmpty, priorInstanceID != currentInstanceID else { return }
        if !currentInstanceID.isEmpty {
            self.journalMarkStore.clear()
        }
        self.journalMark = Self.storedJournalMark()
    }

    private func applyDebugSeeds() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test") else { return }
        self.sunArcDebugOverride = SunArcBackgroundDebugScene.sceneOverride(for: arguments)
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
            case "journalSetup":
                self.openJournalSetup()
            case "shelf":
                self.openYourSolstone()
            case "addMore":
                self.openSources()
            case "import":
                self.nav.selectFromDeck(.import)
            case "shelfJournal":
                self.nav.selectFromDeck(.shelfJournal)
            case "shelfThisDevice":
                self.nav.selectFromDeck(.shelfThisDevice)
            case "shelfNotifications":
                self.nav.selectFromDeck(.shelfNotifications)
            case "shelfHelp":
                self.nav.selectFromDeck(.shelfHelp)
            case "shelfAbout":
                self.nav.selectFromDeck(.shelfAbout)
            case "source:audio":
                self.nav.selectFromDeck(.source(.audio))
            case "source:location":
                self.nav.selectFromDeck(.source(.location))
            case "source:screencast":
                self.nav.selectFromDeck(.source(.screencast))
            case "source:watch":
                self.nav.selectFromDeck(.source(.watch))
            case "source:calendar":
                self.nav.selectFromDeck(.source(.calendar))
            default:
                break
            }
        }
#endif
    }

    private var sourcesBadgeVisible: Bool {
        [
            sourceState(
                for: self.observerManager.state,
                paused: self.observerSourcePauseState.isPaused,
                enrolled: self.observerManager.isEnrolled,
                microphoneTaken: self.observerManager.microphoneTakenPause
            ),
            self.locationManager.sourceState,
            screencastSourceState(for: self.screencastManager.state, enrolled: self.screencastManager.isEnrolled),
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
        case .journal(let path):
            self.openJournal(path: path)
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
