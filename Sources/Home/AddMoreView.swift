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
                // No source list is ever complete; the last card names the door for
                // what isn't here yet — the same support site the help area links to.
                AddMoreSuggestionsCard()
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
            isJournalPaired: self.appConfig.isPaired,
            observerManager: self.observerManager,
            observerSourcePauseState: self.observerSourcePauseState,
            locationManager: self.locationManager,
            screencastManager: self.screencastManager,
            watchLane: self.watchPipelineInputs.assembly(now: self.now).lane
        )
        return SourcesViewRowBuilder.addMoreRows(
            audio: bundle.audio,
            location: bundle.location,
            screencast: bundle.screencast,
            watch: bundle.watch,
            hiddenIDs: UserSettings.decodeHiddenHomeSourceIDs(self.hiddenHomeSourceIDsData)
        )
    }
}

/// Matches `SourceRowView`'s card, with `arrow.up.right` in place of `chevron.right`
/// — this one leaves the app, so it gets the external-link glyph, not the in-app one.
private struct AddMoreSuggestionsCard: View {
    var body: some View {
        Link(destination: URL(string: "https://support.solstone.app")!) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lifepreserver")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.solOrangeAdaptive)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 5) {
                    Text(SourceVocabulary.addMoreSuggestionsTitle)
                        .font(ShellFont.tileName)
                        .foregroundStyle(.primary)
                    Text(SourceVocabulary.addMoreSuggestionsBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(height: 24)
            }
            .padding(ShellMetrics.surfacePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(ShellMetrics.cardShape)
            .background(Color.deckSurface, in: ShellMetrics.cardShape)
            .overlay {
                ShellMetrics.cardShape.stroke(Color.deckHairline, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SourceVocabulary.addMoreSuggestionsTitle). \(SourceVocabulary.addMoreSuggestionsBody)")
        .accessibilityIdentifier("addMore.suggestions")
    }
}
