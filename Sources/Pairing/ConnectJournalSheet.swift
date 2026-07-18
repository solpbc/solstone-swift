// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ConnectJournalSheet: View {
    private enum Destination: Hashable {
        case ownJournal
    }

    @Binding var isPresented: Bool
    @Environment(TunnelManager.self) private var tunnelManager
    @State private var path: [Destination] = []
    @State private var showingJournalLives = false

    var body: some View {
        NavigationStack(path: self.$path) {
            List {
                Section {
                    Text(SourceVocabulary.connectJournalIntro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink(value: Destination.ownJournal) {
                        self.doorRow(
                            label: SourceVocabulary.connectDoorOwnTitle,
                            subtitle: SourceVocabulary.connectDoorOwnSubtitle,
                            systemImage: "desktopcomputer"
                        )
                    }
                    .accessibilityIdentifier("connectJournal.ownJournal")

                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.title3.weight(.semibold))
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(SourceVocabulary.connectDoorOnYourPhoneTitle)
                                .font(.headline)
                                .accessibilityIdentifier("connectJournal.onYourPhone")
                            Text(SourceVocabulary.connectDoorOnYourPhoneBody)
                                .font(.subheadline)
                        }

                        Spacer(minLength: 0)

                        Text(SourceVocabulary.journalLivesComingLater)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("connectJournal.onYourPhone.comingLater")
                    }
                    .padding(.vertical, 6)
                    .foregroundStyle(.secondary)

                    Text(SourceVocabulary.connectJournalFloorLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connectJournal.noJournalYet")

                    Button {
                        self.showingJournalLives = true
                    } label: {
                        Text(SourceVocabulary.connectJournalHowJournalsWork)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.orangeInk)
                    .accessibilityIdentifier("connectJournal.howJournalsWork")
                }
            }
            .accessibilityIdentifier("connectJournal.sheet")
            .navigationTitle("connect a journal")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .ownJournal:
                    PairFlowView(
                        onBack: {
                            if !self.path.isEmpty {
                                self.path.removeLast()
                            }
                        },
                        onComplete: {
                            OwnerPairingCompletion.completeOwnerPairing(tunnelManager: self.tunnelManager)
                            self.isPresented = false
                        }
                    )
                }
            }
            .sheet(isPresented: self.$showingJournalLives) {
                JournalLivesSheet(isPresented: self.$showingJournalLives)
            }
        }
    }

    private func doorRow(label: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.solOrange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
