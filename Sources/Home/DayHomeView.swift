// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
    let onOpenSources: () -> Void
    let onOpenYourSolstone: () -> Void
    let onOpenStatus: () -> Void
    let sourcesBadgeVisible: Bool

    @Environment(AppConfig.self) private var appConfig
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
    @ScaledMetric(relativeTo: .body) private var tileMin: CGFloat = 160
    @State private var containerWidth: CGFloat = 0
    @State private var now = Date()
    @State private var showingJournalLives = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if self.dynamicTypeSize.isAccessibilitySize {
                    self.statusPill
                }
                self.deckGrid
            }
            .padding()
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { self.containerWidth = $0 }
        }
        .accessibilityIdentifier("dayHome.surface")
        .safeAreaBar(edge: .bottom) { self.journalPill }
        .navigationTitle(greeting(forHour: Calendar.current.component(.hour, from: self.now)))
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: ShellDestination.self) { destination in
            ShellDestinationView(destination: destination)
        }
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
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .task { await refreshNowPeriodically { self.now = Date() } }
        .sheet(isPresented: self.$showingJournalLives) {
            JournalLivesSheet(isPresented: self.$showingJournalLives)
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
            watchLane: self.watchPipelineInputs.assembly(now: self.now).lane
        )
    }

    var gridColumns: [GridItem] {
        if self.dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12)]
        }
        if self.containerWidth >= (2 * self.tileMin + 12) {
            return [GridItem(.adaptive(minimum: self.tileMin), spacing: 12)]
        }
        return [GridItem(.flexible(), spacing: 12)]
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
                        await self.observerManager.startSession(mode: mode)
                        self.observerManager.persistEnrolledIfActive()
                    } else {
                        await self.observerManager.stopSession()
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

    var statusLine: String {
        if !self.appConfig.isPaired {
            return SourceVocabulary.dayLocalityNoJournal
        }
        return self.connectionSyncModel.status.statusLine
    }

    var backlogCount: Int {
        let totals = uploadTotals(
            mobileSegment: self.mobileSegmentTransferHolder,
            omi: self.omiUploaderHolder,
            watch: self.watchUploaderHolder,
            share: self.shareTransferHolder
        )
        return totals.pending + totals.failed
    }

    var statusPill: some View {
        Button(action: self.onOpenStatus) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.statusLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if self.backlogCount > 0 {
                    Text("\(self.backlogCount)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .tint(.primary)
        .matchedTransitionSource(id: HomeChromeID.status, in: self.homeChrome)
        .accessibilityIdentifier("dayHome.statusPill")
        .accessibilityValue(self.statusPillAccessibilityValue)
    }

    var statusPillAccessibilityValue: String {
        if self.backlogCount > 0 {
            return "\(self.statusLine), \(self.backlogCount) \(SourceVocabulary.waitingToSync)"
        }
        return self.statusLine
    }

    var journalPill: some View {
        Button {
            switch self.journalState {
            case .linkedOnline:
                self.onOpenJournal()
            case .noJournal, .linkedOffline:
                self.showingJournalLives = true
            }
        } label: {
            HStack(spacing: 8) {
                if let mark = self.journalMark {
                    JournalMarkCompactChips(mark: mark)
                }
                Text(self.journalPillTitle)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.primary)
        .controlSize(.regular)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier(
            self.journalState == .linkedOnline ? "dayHome.openInJournal" : "dayHome.journalSetup"
        )
    }

    var journalPillTitle: String {
        switch self.journalState {
        case .linkedOnline:
            SourceVocabulary.openInJournal
        case .linkedOffline:
            SourceVocabulary.journalLivesRepairAction
        case .noJournal:
            SourceVocabulary.onThisPhoneConnectJournalButton
        }
    }

    var shelfButton: some View {
        Button {
            self.onOpenYourSolstone()
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("dev-copy: settings")
        .accessibilityIdentifier("dayHome.yourSolstoneEntry")
    }
}
