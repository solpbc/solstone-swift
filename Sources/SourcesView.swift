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
    @Environment(WatchLink.self) private var watchLink
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

                        SourceRowView(source: self.audioSource) {
                            self.selectedSourceRoute = .audio
                        }
                        SourceRowView(source: self.locationSource) {
                            self.selectedSourceRoute = .location
                        }
                        SourceRowView(source: self.screencastSource) {
                            self.selectedSourceRoute = .screencast
                        }
                        SourceRowView(source: self.omiSource) {
                            self.selectedSourceRoute = .omi
                        }
                        SourceRowView(source: self.watchSource) {
                            self.selectedSourceRoute = .watch
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(SourceGroup.bringingInYourself.header)
                            .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))

                        SourceRowView(source: self.shareSource) {
                            self.selectedSourceRoute = .share
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

private enum SourceRoute: Hashable, Identifiable {
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

    var watchSource: Source {
        let lastReceivedAt = self.watchLink.lastReceivedAt
        let install = watchInstallState(
            isSupported: self.watchLink.isSupported,
            isPaired: self.watchLink.isPaired,
            isWatchAppInstalled: self.watchLink.isWatchAppInstalled,
            activationState: self.watchLink.activationState,
            now: self.now,
            lastReceivedAt: lastReceivedAt
        )
        let recordingStatus = watchRecordingStatus(
            context: self.watchLink.watchStatus,
            now: self.now,
            lastReceivedAt: lastReceivedAt
        )
        let presentation = phoneWatchSourcePresentation(
            install: install,
            recordingStatus: recordingStatus,
            isReachable: self.watchLink.isReachable,
            isJournalPaired: self.appConfig.isPaired
        )
        return Source(
            id: "watch",
            displayName: SourceVocabulary.watchSourceDisplayName,
            kind: .watch,
            group: .experiencingAlongsideYou,
            state: presentation.state,
            isJournalPaired: self.appConfig.isPaired,
            activeSubtext: SourceVocabulary.watchListeningSubtext,
            subtextOverride: presentation.subtext,
            attention: presentation.attention,
            pendingStatus: .nonePending,
            detailSubtext: presentation.attention?.message
        )
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
