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
    let onOpenSources: () -> Void
    let onOpenYourSolstone: () -> Void
    let sourcesBadgeVisible: Bool
    @State private var showingJournalLives = false

    var body: some View {
        OnThisPhoneMomentsView(
            onTurnOnSource: self.onTurnOnSource,
            journalState: self.journalState
        ) {
            self.header
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    self.onOpenSources()
                } label: {
                    Image(systemName: "square.stack.3d.up")
                        .overlay(alignment: .topTrailing) {
                            if self.sourcesBadgeVisible {
                                Circle()
                                    .fill(Color.solOrange)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }
                        }
                }
                .accessibilityLabel("sources")
                .accessibilityIdentifier("dayHome.sourcesEntry")
                .accessibilityValue(self.sourcesBadgeVisible ? "attention" : "clear")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    self.onOpenYourSolstone()
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(SourceVocabulary.yourSolstoneTitle)
                .accessibilityIdentifier("dayHome.yourSolstoneEntry")
            }
        }
        .preferredColorScheme(.light)
        .background(Color.solCream.ignoresSafeArea())
        .toolbarBackground(Color.solCream, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image("SolWordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)

            Text(greeting(forHour: Calendar.current.component(.hour, from: Date())))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("dayHome.greeting")

            Button {
                switch self.journalState {
                case .linkedOffline:
                    self.onOpenYourSolstone()
                case .noJournal, .linkedOnline:
                    self.showingJournalLives = true
                }
            } label: {
                self.localityLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dayHome.locality")
            .accessibilityLabel(self.localityAccessibilityLabel)
            .accessibilityHint(self.localityAccessibilityHint)
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

    @ViewBuilder
    private var localityLabel: some View {
        switch self.journalState {
        case .noJournal, .linkedOffline:
            self.localityChip(self.localityText)
        case .linkedOnline:
            Text(self.localityText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func localityChip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .foregroundStyle(.secondary)
            Text("›")
                .foregroundStyle(Color.orangeInk)
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(Color.solCream, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.orangeInk.opacity(0.32), lineWidth: 0.5)
        }
    }

    private var localityText: String {
        switch self.journalState {
        case .noJournal:
            SourceVocabulary.dayLocalityNoJournal
        case .linkedOffline:
            SourceVocabulary.journalOffline
        case .linkedOnline:
            SourceVocabulary.journalConnected
        }
    }

    private var localityAccessibilityLabel: String {
        switch self.journalState {
        case .noJournal:
            "on this device, not paired"
        case .linkedOffline, .linkedOnline:
            self.localityText
        }
    }

    private var localityAccessibilityHint: String {
        switch self.journalState {
        case .linkedOffline:
            "opens your journal connection details"
        case .noJournal, .linkedOnline:
            "opens where your journal lives"
        }
    }
}
