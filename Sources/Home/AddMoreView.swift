// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct AddMoreView: View {
    let onSelect: (SourceRoute) -> Void
    @Environment(AppConfig.self) private var appConfig
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverSourcePauseState.self) private var observerSourcePauseState
    @Environment(LocationManager.self) private var locationManager
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(OmiSourceManager.self) private var omiSourceManager
    @WatchPipelineInputReader private var watchPipelineInputs
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(UserSettings.hiddenHomeSourceIDsKey) private var hiddenHomeSourceIDsData = Data()
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(self.rows) { row in
                    SourceRowView(source: row.source) {
                        self.onSelect(row.route)
                    }
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(SourceVocabulary.addMoreTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("shell.pane.addMore")
        .task {
            await refreshNowPeriodically { self.now = Date() }
        }
    }

    private var rows: [SourcesViewRow] {
        let bundle = makeHomeSourceBundle(
            now: self.now,
            isJournalPaired: self.appConfig.isPaired,
            observerManager: self.observerManager,
            observerSourcePauseState: self.observerSourcePauseState,
            locationManager: self.locationManager,
            screencastManager: self.screencastManager,
            omiSourceManager: self.omiSourceManager,
            watchLane: self.watchPipelineInputs.assembly(now: self.now).lane
        )
        return SourcesViewRowBuilder.addMoreRows(
            audio: bundle.audio,
            location: bundle.location,
            screencast: bundle.screencast,
            omi: bundle.omi,
            watch: bundle.watch,
            hiddenIDs: UserSettings.decodeHiddenHomeSourceIDs(self.hiddenHomeSourceIDsData)
        )
    }
}
