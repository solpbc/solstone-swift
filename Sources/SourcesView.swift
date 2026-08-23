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
                            audio: self.bundle.audio,
                            location: self.bundle.location,
                            screencast: self.bundle.screencast,
                            omi: self.bundle.omi,
                            watch: self.bundle.watch
                        )) { row in
                            SourceRowView(source: row.source) {
                                self.selectedSourceRoute = row.route
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(SourceGroup.bringingInYourself.header)
                            .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))

                        ForEach(SourcesViewRowBuilder.importRows(share: self.bundle.share)) { row in
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
                ShellDestinationView(destination: .source(route))
            }
            .task {
                await refreshNowPeriodically { self.now = Date() }
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

private extension SourcesView {
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
}
