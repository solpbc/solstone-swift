// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourcesView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverSourcePauseState.self) private var observerSourcePauseState
    @Environment(LocationManager.self) private var locationManager
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(OmiSourceManager.self) private var omiSourceManager
    @WatchPipelineInputReader private var watchPipelineInputs
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSourceRoute: SourceRoute?
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(SourceGroup.experiencingAlongsideYou.header)
                            .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))

                        ForEach(SourcesViewRowBuilder.primaryRows(
                            audio: self.audioSource,
                            location: self.locationSource,
                            screencast: self.screencastSource,
                            omi: self.omiSource,
                            watch: self.watchSource
                        )) { row in
                            SourceRowView(source: row.source) {
                                self.selectedSourceRoute = row.route
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(SourceGroup.bringingInYourself.header)
                            .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))

                        ForEach(SourcesViewRowBuilder.importRows(share: self.shareSource)) { row in
                            SourceRowView(source: row.source) {
                                self.selectedSourceRoute = row.route
                            }
                        }
                    }

                }
                .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("sources")
                        .font(.custom("Comfortaa-Bold", size: 22, relativeTo: .title2))
                }
            }
            .navigationDestination(item: self.$selectedSourceRoute) { route in
                switch route {
                case .audio:
                    SourceDetailView()
                case .location:
                    LocationSourceDetailView()
                case .screencast:
                    ScreencastSourceDetailView()
                case .omi:
                    OmiSourceDetailView()
                case .watch:
                    WatchSourceDetailView()
                case .share:
                    ImporterSourceDetailView(source: self.shareSource)
                }
            }
            .task {
                await self.refreshNowPeriodically()
            }
        }
    }
}

nonisolated enum SourceRoute: Hashable, Identifiable, Sendable {
    case audio, location, screencast, omi, watch, share

    var id: String {
        switch self {
        case .audio: "audio"
        case .location: "location"
        case .screencast: "screencast"
        case .omi: "omi"
        case .watch: "watch"
        case .share: "share"
        }
    }
}

nonisolated struct SourcesViewRow: Identifiable, Equatable, Sendable {
    let route: SourceRoute
    let source: Source

    var id: String { self.route.id }
}

nonisolated enum SourcesViewRowBuilder {
    static func primaryRows(
        audio: Source,
        location: Source,
        screencast: Source,
        omi: Source,
        watch: Source?
    ) -> [SourcesViewRow] {
        var rows = [
            SourcesViewRow(route: .audio, source: audio),
            SourcesViewRow(route: .location, source: location),
            SourcesViewRow(route: .screencast, source: screencast),
            SourcesViewRow(route: .omi, source: omi),
        ]
        if let watch {
            rows.append(SourcesViewRow(route: .watch, source: watch))
        }
        return rows
    }

    static func importRows(share: Source) -> [SourcesViewRow] {
        [SourcesViewRow(route: .share, source: share)]
    }
}

nonisolated func watchSourceModel(from lane: PhoneWatchSourceLane, isJournalPaired: Bool) -> Source? {
    guard lane != .unsupported else {
        return nil
    }
    let presentation = phoneWatchSourcePresentation(lane: lane)
    return Source(
        id: "watch",
        displayName: SourceVocabulary.watchSourceDisplayName,
        kind: .watch,
        group: .experiencingAlongsideYou,
        state: presentation.state,
        isJournalPaired: isJournalPaired,
        activeSubtext: SourceVocabulary.watchListeningSubtext,
        subtextOverride: presentation.subtext,
        attention: presentation.attention,
        pendingStatus: .nonePending,
        showsSubtext: presentation.subtext != nil
    )
}

private extension SourcesView {
    var audioSource: Source {
        let state = sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused)
        let attention: SourceAttention?
        if case .error(let error) = self.observerManager.state {
            attention = SourceAttention(message: error.message)
        } else {
            attention = nil
        }

        return Source(
            id: "audio",
            displayName: "audio",
            kind: .observer,
            group: .experiencingAlongsideYou,
            state: state,
            isJournalPaired: self.appConfig.isPaired,
            activeSubtext: SourceVocabulary.observerActiveSubtext,
            attention: attention,
            pendingStatus: .nonePending
        )
    }

    var shareSource: Source {
        return Source(
            id: "share-sheet",
            displayName: SourceVocabulary.shareSheetDisplayName,
            kind: .importer,
            group: .bringingInYourself,
            state: .active,
            isJournalPaired: self.appConfig.isPaired,
            activeSubtext: SourceVocabulary.shareAlwaysOnSubtext(isJournalPaired: self.appConfig.isPaired),
            attention: nil,
            pendingStatus: .nonePending
        )
    }

    var locationSource: Source {
        return Source(
            id: "location",
            displayName: LocationVocabulary.sourceDisplayName,
            kind: .location,
            group: .experiencingAlongsideYou,
            state: self.locationManager.sourceState,
            isJournalPaired: self.appConfig.isPaired,
            activeSubtext: LocationVocabulary.activeSubtext(isJournalPaired: self.appConfig.isPaired),
            attention: self.locationManager.sourceAttention,
            pendingStatus: .nonePending
        )
    }

    var screencastSource: Source {
        screencastSourcePresentation(
            managerState: self.screencastManager.state,
            isJournalPaired: self.appConfig.isPaired
        )
    }

    var omiSource: Source {
        let now = self.now
        let effectiveState = self.omiSourceManager.effectiveConnectionState(now: now)
        let mapped = omiSourceState(
            for: effectiveState,
            enabled: self.omiSourceManager.enabled
        )
        let battery = OmiSourceLogic.surfacedBattery(
            live: self.omiSourceManager.battery,
            lastKnown: self.omiSourceManager.lastKnownBattery
        )
        let signal = OmiSourceLogic.surfacedSignal(
            live: self.omiSourceManager.connectedRSSI,
            lastKnown: self.omiSourceManager.lastKnownSignal
        )
        return Source(
            id: "omi",
            displayName: "omi pendant",
            kind: .omi,
            group: .experiencingAlongsideYou,
            state: mapped.0,
            isJournalPaired: self.appConfig.isPaired,
            activeSubtext: SourceVocabulary.observerActiveSubtext,
            attention: mapped.1,
            pendingStatus: .nonePending,
            // VPX: tune row summary composition once multiple last-known states are visible.
            detailSubtext: OmiSourceLogic.sourceReadingSubtext(
                battery: battery,
                signal: signal,
                now: now
            )
        )
    }

    var watchSource: Source? {
        let assembly = self.watchPipelineInputs.assembly(now: self.now)
        return watchSourceModel(from: assembly.lane, isJournalPaired: self.appConfig.isPaired)
    }

    func refreshNowPeriodically() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else {
                return
            }
            self.now = Date()
        }
    }
}
