// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import SwiftUI

func greeting(forHour hour: Int) -> String {
    switch hour {
    case 5...11: return SourceVocabulary.greetingMorning
    case 12...16: return SourceVocabulary.greetingAfternoon
    default: return SourceVocabulary.greetingEvening
    }
}

nonisolated enum DayHomeJournalState: Equatable, Sendable {
    case noJournal
    case linkedOffline
    case linkedOnline
}

nonisolated func dayHomeJournalState(
    isPaired: Bool,
    status: ConnectionSyncStatus
) -> DayHomeJournalState {
    if !isPaired {
        return .noJournal
    }
    switch status {
    case .connectedIdle, .connectedWaiting, .connectedTransferring:
        return .linkedOnline
    case .offline, .connecting, .waitingForHome, .reconnecting, .unreachable:
        return .linkedOffline
    }
}

/// Fixed measurements the deck grid is laid out from.
///
/// Every number here is either measured from the deck's own modifiers or derived
/// from the others.
nonisolated enum DeckMetrics {
    /// The deck's `.padding()`, 16 pt per side. The grid lays out inside it, so a
    /// column must carry this on top of what the tiles need.
    static let horizontalPadding: CGFloat = 32
    static let tileSpacing: CGFloat = 12

    /// One tile minimum, everywhere. A source tile puts a 44 pt control beside its
    /// label with 14 pt of padding either side, so a tile narrower than this
    /// truncates the source name mid-word rather than merely wrapping it.
    static let tileMinimum: CGFloat = 160

    /// The deck never goes wider than this many columns, however much room there is.
    /// Past four, tiles stop reading as a set of things the owner owns and start
    /// reading as a toolbar.
    static let maximumColumns: Int = 4

    /// The column width at which two tiles first fit at the default text size.
    /// Derived, so it cannot drift from `tileMinimum`.
    static var twoColumnThreshold: CGFloat {
        2 * self.tileMinimum + self.tileSpacing + self.horizontalPadding
    }

    /// The band the deck column is pinned to in the split.
    ///
    /// `columnMinimum` is the upper bound on the collapse threshold: at this width
    /// and above, the split must not collapse. It is set so two tiles stay
    /// readable one Dynamic Type step above the default, which needs more room
    /// than `twoColumnThreshold` reserves at the default size.
    static let columnMinimum: CGFloat = 404
    static let columnIdeal: CGFloat = 412
    static let columnMaximum: CGFloat = 420
}

/// How the deck lays out at one width and text size.
nonisolated struct DeckLayout: Equatable, Sendable {
    /// The scaled minimum width of one tile.
    let tileMinimum: CGFloat
    /// How many equal columns the deck draws: 1 when only one tile fits, 2 at every
    /// phone-portrait and pinned-column width, more on a wide deck up to
    /// `DeckMetrics.maximumColumns`.
    let columnCount: Int
}

private struct AppGroupSnapshotInputs: Equatable {
    let observerState: ObserverState
    let bundle: HomeSourceBundle
    let backlogCount: WatchAwareBacklog
    let pairing: AppGroupMirror.PairingSnapshot
    let microphonePermission: AppGroupMirror.MicrophonePermissionSnapshot
}

/// `.body` point sizes over the default, matching what
/// `@ScaledMetric(relativeTo: .body)` computes, but callable from a test at a
/// named `DynamicTypeSize`.
nonisolated func bodyTextScale(for size: DynamicTypeSize) -> CGFloat {
    let points: CGFloat = switch size {
    case .xSmall: 14
    case .small: 15
    case .medium: 16
    case .large: 17
    case .xLarge: 19
    case .xxLarge: 21
    case .xxxLarge: 23
    case .accessibility1: 28
    case .accessibility2: 33
    case .accessibility3: 40
    case .accessibility4: 47
    case .accessibility5: 53
    @unknown default: 17
    }
    return points / 17
}

/// The deck's layout decision, from measured column width and text size alone.
///
/// `columnWidth` is the full width of the column the deck occupies, including the
/// deck's own padding; this function subtracts it.
nonisolated func deckLayout(columnWidth: CGFloat, dynamicTypeSize: DynamicTypeSize) -> DeckLayout {
    let minimum = DeckMetrics.tileMinimum * bodyTextScale(for: dynamicTypeSize)
    if dynamicTypeSize.isAccessibilitySize {
        return DeckLayout(tileMinimum: minimum, columnCount: 1)
    }
    let available = columnWidth - DeckMetrics.horizontalPadding
    // As many equal columns as the width honestly holds, capped. Two is the answer
    // at every phone-portrait and pinned-column width; a landscape phone is twice
    // that wide, and holding it to two there pushed the last tiles off a screen only
    // ~390 pt tall — the deck's whole job is to show every source at once.
    let fits = Int((available + DeckMetrics.tileSpacing) / (minimum + DeckMetrics.tileSpacing))
    return DeckLayout(
        tileMinimum: minimum,
        columnCount: max(1, min(DeckMetrics.maximumColumns, fits))
    )
}

/// Whether a split shell has to collapse rather than show a one-column deck.
///
/// The deck is never degenerated to one column inside a split: if the pinned
/// leading column cannot hold two tiles, the split collapses and the shell
/// behaves as compact. Evaluated at the pinned column, so it depends only on the
/// text size.
nonisolated func splitCollapses(dynamicTypeSize: DynamicTypeSize) -> Bool {
    deckLayout(
        columnWidth: DeckMetrics.columnIdeal,
        dynamicTypeSize: dynamicTypeSize
    ).columnCount < 2
}

func refreshNowPeriodically(update: @escaping () -> Void) async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else {
            return
        }
        update()
    }
}

struct DayHomeView: View {
    let journalState: DayHomeJournalState
    let journalMark: JournalMark?
    let homeChrome: Namespace.ID
    let onOpenJournal: () -> Void
    let onOpenJournalSetup: () -> Void
    let onOpenSources: () -> Void
    let onOpenYourSolstone: () -> Void
    let onOpenStatus: () -> Void
    let sourcesBadgeVisible: Bool

    @Environment(AppConfig.self) private var appConfig
    @Environment(AppGroupMirror.self) private var appGroupMirror
    @Environment(WatchBacklogSnapshotWriter.self) private var watchBacklogSnapshotWriter
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverSourcePauseState.self) private var observerSourcePauseState
    @Environment(LocationManager.self) private var locationManager
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(OmiSourceManager.self) private var omiSourceManager
    @WatchPipelineInputReader private var watchPipelineInputs
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(OmiUploaderHolder.self) private var omiUploaderHolder
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(ShareTransferHolder.self) private var shareTransferHolder
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("sense.preferredMode") private var preferredMode = ObserverMode.meeting.rawValue
    @AppStorage(UserSettings.hiddenHomeSourceIDsKey) private var hiddenHomeSourceIDsData = Data()
    /// The full width of the column the deck occupies, including the deck's own
    /// padding. Measured on the scroll view so the value cannot depend on which
    /// side of `.padding()` the geometry read sits.
    @State private var deckColumnWidth: CGFloat = 0
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellMetrics.gutter) {
                if self.dynamicTypeSize.isAccessibilitySize {
                    self.statusPill
                }
                self.deckGrid
            }
            .padding(ShellMetrics.screenMargin)
            .padding(.bottom, 8)
            // The deck is the container its tiles are concentric within. Without this
            // `ConcentricRectangle` has no container to derive from and every tile
            // renders as a hard-cornered rectangle, which is what shipped.
            .containerShape(.rect(cornerRadius: ShellMetrics.containerRadius))
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { self.deckColumnWidth = $0 }
        .accessibilityIdentifier("dayHome.surface")
        .safeAreaBar(edge: .bottom) { self.journalPill }
        .navigationTitle(greeting(forHour: Calendar.current.component(.hour, from: self.now)))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                self.shelfButton
            }
            if !self.dynamicTypeSize.isAccessibilitySize {
                ToolbarItem(placement: .topBarTrailing) {
                    self.statusPill
                }
            }
        }
        .background(Color.deckGround.ignoresSafeArea())
        .task { await refreshNowPeriodically { self.now = Date() } }
        .task(id: self.appGroupSnapshotInputs) {
            _ = self.appGroupMirror.updateSessionAndSources(
                pairing: self.appGroupPairing,
                microphonePermission: self.appGroupMicrophonePermission,
                session: self.appGroupSessionState,
                sourceStates: self.appGroupSourceStates,
                backlogCount: self.backlogCount.knownCount
            )
            self.watchBacklogSnapshotWriter.write(
                backlog: self.backlogCount,
                watchStatusAsOf: self.watchPipelineAssembly.input.watchStatus?.asOf
            )
        }
    }
}

private extension DayHomeView {
    var bundle: HomeSourceBundle {
        makeHomeSourceBundle(
            now: self.now,
            isJournalPaired: self.appConfig.isPaired,
            observerManager: self.observerManager,
            observerSourcePauseState: self.observerSourcePauseState,
            locationManager: self.locationManager,
            screencastManager: self.screencastManager,
            omiSourceManager: self.omiSourceManager,
            watchLane: self.watchPipelineAssembly.lane
        )
    }

    var appGroupSnapshotInputs: AppGroupSnapshotInputs {
        AppGroupSnapshotInputs(
            observerState: self.observerManager.state,
            bundle: self.bundle,
            backlogCount: self.backlogCount,
            pairing: self.appGroupPairing,
            microphonePermission: self.appGroupMicrophonePermission
        )
    }

    var watchPipelineAssembly: WatchPipelineAssembly {
        self.watchPipelineInputs.assembly(now: self.now)
    }

    var appGroupPairing: AppGroupMirror.PairingSnapshot {
        AppGroupMirror.PairingSnapshot(
            journalName: self.appConfig.isPaired ? self.appConfig.homeLabel : nil,
            isPaired: self.appConfig.isPaired
        )
    }

    var appGroupMicrophonePermission: AppGroupMirror.MicrophonePermissionSnapshot {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            .granted
        case .undetermined:
            .undetermined
        case .denied:
            .denied
        @unknown default:
            .denied
        }
    }

    var appGroupSessionState: AppGroupMirror.SessionState {
        guard case .active(let session) = self.observerManager.state else {
            return .notLive
        }
        return .live(mode: session.mode, startedAt: session.startedAt)
    }

    var appGroupSourceStates: [SourceKind: SourceState] {
        let sources = [
            self.bundle.audio,
            self.bundle.location,
            self.bundle.screencast,
            self.bundle.omi,
        ] + (self.bundle.watch.map { [$0] } ?? [])
        return Dictionary(uniqueKeysWithValues: sources.map { ($0.kind, $0.state) })
    }

    var layout: DeckLayout {
        deckLayout(columnWidth: self.deckColumnWidth, dynamicTypeSize: self.dynamicTypeSize)
    }

    /// Two equal columns, or one. `.adaptive` was letting the grid pick a column
    /// count per row, which is what produced the ragged deck; the contract calls for
    /// an even grid, so the columns are fixed and equal.
    var gridColumns: [GridItem] {
        let layout = self.layout
        return Array(
            repeating: GridItem(.flexible(), spacing: DeckMetrics.tileSpacing),
            count: max(1, layout.columnCount)
        )
    }

    var hiddenHomeSourceIDs: Set<String> {
        UserSettings.decodeHiddenHomeSourceIDs(self.hiddenHomeSourceIDsData)
    }

    func isOnHome(_ id: String) -> Bool {
        isHomeSourceVisible(id: id, hiddenIDs: self.hiddenHomeSourceIDs)
    }

    var deckGrid: some View {
        LazyVGrid(columns: self.gridColumns, spacing: 12) {
            if self.isOnHome(self.bundle.audio.id) {
                HomeSourceTile(
                    source: self.bundle.audio,
                    route: .audio,
                    control: .toggle,
                    isOn: self.audioIsOn
                )
            }
            if self.isOnHome(self.bundle.location.id) {
                HomeSourceTile(
                    source: self.bundle.location,
                    route: .location,
                    control: .toggle,
                    isOn: self.locationIsOn
                )
            }
            if self.isOnHome(self.bundle.screencast.id) {
                HomeSourceTile(
                    source: self.bundle.screencast,
                    route: .screencast,
                    control: .toggle,
                    isOn: self.screencastIsOn,
                    presentsScreencastPicker: true,
                    onScreencastWillOpen: { self.screencastManager.beginStarting() }
                )
            }
            if self.isOnHome(self.bundle.omi.id) {
                HomeSourceTile(
                    source: self.bundle.omi,
                    route: .omi,
                    control: .toggle,
                    isOn: self.omiIsOn
                )
            }
            if let watch = self.bundle.watch, self.isOnHome(watch.id) {
                HomeSourceTile(
                    source: watch,
                    route: .watch,
                    control: .none
                )
            }
            HomeImportTile()
            HomeAddMoreTile(badgeVisible: self.sourcesBadgeVisible) {
                self.onOpenSources()
            }
        }
    }

    var audioIsOn: Binding<Bool> {
        Binding(
            get: {
                switch sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused) {
                case .active, .enrolling:
                    true
                case .off, .paused, .readyToSetUp, .checking, .needsAttention:
                    false
                }
            },
            set: { isOn in
                Task { @MainActor in
                    if isOn {
                        self.observerSourcePauseState.isPaused = false
                        let mode = ObserverMode(rawValue: self.preferredMode) ?? .meeting
                        _ = await self.observerManager.startSession(mode: mode)
                        self.observerManager.persistEnrolledIfActive()
                    } else {
                        _ = await self.observerManager.stopSession()
                    }
                }
            }
        )
    }

    var locationIsOn: Binding<Bool> {
        Binding(
            get: {
                switch self.locationManager.sourceState {
                case .active, .enrolling:
                    true
                case .off, .paused, .readyToSetUp, .checking, .needsAttention:
                    false
                }
            },
            set: { isOn in
                Task { @MainActor in
                    if isOn {
                        if self.locationManager.sourceState == .paused {
                            await self.locationManager.resume()
                        } else {
                            await self.locationManager.start(tier: .defaultTier)
                        }
                    } else {
                        await self.locationManager.pause()
                    }
                }
            }
        )
    }

    var screencastIsOn: Binding<Bool> {
        Binding(
            get: {
                switch self.screencastManager.state {
                case .active, .starting:
                    true
                case .off, .needsAttention, .unavailable:
                    false
                }
            },
            set: { _ in }
        )
    }

    var omiIsOn: Binding<Bool> {
        Binding(
            get: { self.omiSourceManager.enabled },
            set: { isOn in
                if isOn {
                    self.omiSourceManager.enable()
                } else {
                    self.omiSourceManager.disable()
                }
            }
        )
    }

    var backlogCount: WatchAwareBacklog {
        let totals = captureUploadTotals(
            mobileSegment: self.mobileSegmentTransferHolder,
            omi: self.omiUploaderHolder,
            watch: self.watchUploaderHolder
        )
        return .known(totals.pending + totals.failed)
    }

    var statusPillState: HomeStatusPillState {
        HomeStatusPillState.resolve(
            isPaired: self.appConfig.isPaired,
            status: self.connectionSyncModel.status,
            hasBacklog: self.backlogCount.knownCount > 0
        )
    }

    var statusPill: some View {
        Button(action: self.onOpenStatus) {
            HomeStatusPillLabel(state: self.statusPillState, backlog: self.backlogCount)
        }
        .tint(.primary)
        .matchedTransitionSource(id: HomeChromeID.status, in: self.homeChrome)
        .accessibilityIdentifier("dayHome.statusPill")
        .accessibilityValue(self.statusPillAccessibilityValue)
    }

    var statusPillAccessibilityValue: String {
        switch self.backlogCount {
        case .known(let count) where count > 0:
            return "\(self.statusPillState.label), \(count) \(SourceVocabulary.waitingToSync)"
        case .partiallyUnknown(let known, let asOf):
            let status = asOf.map {
                SourceVocabulary.watchStatusAsOf(
                    WatchPipelineReducer.relativeText(secondsAgo: max(0, self.now.timeIntervalSince($0)))
                )
            } ?? SourceVocabulary.watchStatusUnknownReason
            return "\(self.statusPillState.label), \(known) \(SourceVocabulary.waitingToSync), \(status)"
        case .known:
            return self.statusPillState.label
        }
    }

    var journalPill: some View {
        Button {
            switch self.journalState {
            case .linkedOnline:
                self.onOpenJournal()
            case .noJournal, .linkedOffline:
                self.onOpenJournalSetup()
            }
        } label: {
            HStack(spacing: 8) {
                // Identity is on the pill in every state: the journal's own mark when
                // there is one, the generic dashed mark when there is not. The pill had
                // shown no chips at all while unpaired.
                if let mark = self.journalMark {
                    JournalMarkCompactChips(mark: mark)
                } else {
                    JournalMarkCompactGenericChips()
                }
                Text(self.journalPillTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
        .tint(.primary)
        .controlSize(.regular)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier(
            self.journalState == .linkedOnline ? "dayHome.openInJournal" : "dayHome.journalSetup"
        )
    }

    /// The pill is the journal's identity, not an action label. It carries the mark's
    /// chips *and* its two words whenever there is a journal to name, so home always
    /// answers "which journal am I feeding" — the one question the shell puts here and
    /// nowhere else. Only the no-journal case has no name to show, so only it reads as
    /// an invitation.
    var journalPillTitle: String {
        switch self.journalState {
        case .linkedOnline, .linkedOffline:
            journalPaneTitle(mark: self.journalMark)
        case .noJournal:
            SourceVocabulary.onThisPhoneConnectJournalButton
        }
    }

    /// The shelf control.
    ///
    /// ⚠ This was `ellipsis.circle`, which is the platform's word for *more actions* —
    /// it promises a popup menu of verbs. The shelf is not that: it is a panel of
    /// places. Three lines is the one glyph every owner already reads as "a panel of
    /// navigation lives behind this", and it is what the reference apps use. The
    /// contract deliberately leaves this glyph an open slot.
    var shelfButton: some View {
        Button {
            self.onOpenYourSolstone()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(SourceVocabulary.settingsTitle)
        .accessibilityIdentifier("dayHome.yourSolstoneEntry")
    }
}
