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

struct DayHomeView: View {
    let onTurnOnSource: () -> Void
    @State private var showingJournalLives = false

    var body: some View {
        OnThisPhoneMomentsView(onTurnOnSource: self.onTurnOnSource, showsAskBar: true) {
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
                Text(SourceVocabulary.dayLocality)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dayHome.locality")
            .sheet(isPresented: self.$showingJournalLives) {
                JournalLivesSheet(isPresented: self.$showingJournalLives)
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
}
