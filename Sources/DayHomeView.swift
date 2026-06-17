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

enum DayHomeJournalState: Equatable {
    case noJournal
    case linkedOffline
    case linkedOnline
}

struct DayHomeView: View {
    let journalState: DayHomeJournalState
    let onTurnOnSource: () -> Void
    let onOpenJournal: () -> Void
    let onPresentChat: () -> Void
    @State private var showingJournalLives = false

    var body: some View {
        OnThisPhoneMomentsView(
            onTurnOnSource: self.onTurnOnSource,
            askBarState: self.journalState,
            onAskBarChat: self.onPresentChat
        ) {
            self.header
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image("SolRing")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)

            Text(greeting(forHour: Calendar.current.component(.hour, from: Date())))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("dayHome.greeting")

            Button {
                self.showingJournalLives = true
            } label: {
                Text(self.localityText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dayHome.locality")
            .sheet(isPresented: self.$showingJournalLives) {
                JournalLivesSheet(isPresented: self.$showingJournalLives)
            }

            if self.journalState == .linkedOnline {
                Button {
                    self.onOpenJournal()
                } label: {
                    Text("\(SourceVocabulary.openInJournal) ↗")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("dayHome.openInJournal")
            }

            self.statCardsSlot

            Text(SourceVocabulary.dayToday)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dayHome.surface")
    }

    private var statCardsSlot: some View { EmptyView() }

    private var localityText: String {
        switch self.journalState {
        case .noJournal:
            SourceVocabulary.dayLocality
        case .linkedOffline:
            SourceVocabulary.journalOffline
        case .linkedOnline:
            SourceVocabulary.journalConnected
        }
    }
}
