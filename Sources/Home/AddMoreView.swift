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
            VStack(alignment: .leading, spacing: ShellMetrics.sectionGap) {
                // The two groups the surface exists to distinguish: what could join
                // home, then what is already there. The ordering was already correct
                // and unlabelled, so the list read as one undifferentiated column.
                self.section(SourceVocabulary.addMoreNotOnHome, rows: self.notOnHome)
                self.section(SourceVocabulary.addMoreAlreadyOnHome, rows: self.alreadyOnHome)
                Text(SourceVocabulary.addMoreFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding(ShellMetrics.screenMargin)
            .frame(maxWidth: .infinity)
        }
        .background(Color.deckGround.ignoresSafeArea())
        .navigationTitle(SourceVocabulary.addMoreTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("shell.pane.addMore")
        .task {
            await refreshNowPeriodically { self.now = Date() }
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [SourcesViewRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: ShellMetrics.sectionSpacing) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.leading, 4)
                VStack(alignment: .leading, spacing: ShellMetrics.gutter) {
                    ForEach(rows) { row in
                        SourceRowView(source: row.source) {
                            self.onSelect(row.route)
                        }
                    }
                }
            }
        }
    }

    private var notOnHome: [SourcesViewRow] {
        let hidden = UserSettings.decodeHiddenHomeSourceIDs(self.hiddenHomeSourceIDsData)
        return self.rows.filter { !isHomeSourceVisible(id: $0.source.id, hiddenIDs: hidden) }
    }

    private var alreadyOnHome: [SourcesViewRow] {
        let hidden = UserSettings.decodeHiddenHomeSourceIDs(self.hiddenHomeSourceIDsData)
        return self.rows.filter { isHomeSourceVisible(id: $0.source.id, hiddenIDs: hidden) }
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
