// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct JournalLivesSheet: View {
    private enum Destination: Hashable {
        case connect
    }

    @Binding var isPresented: Bool
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var path: [Destination] = []

    var body: some View {
        NavigationStack(path: self.$path) {
            List {
                Section {
                    Text(SourceVocabulary.journalLivesPromise)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("journalLives.promise")
                }

                Section {
                    NavigationLink(value: Destination.connect) {
                        self.positionRow(
                            rowID: "journalLives.ownJournal",
                            title: SourceVocabulary.journalLivesOwnTitle,
                            body: SourceVocabulary.journalLivesOwnBody,
                            current: self.appConfig.isPaired
                        ) {
                            Text(SourceVocabulary.journalLivesAction(isPaired: self.appConfig.isPaired))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(self.colorScheme == .dark ? Color.primary : Color.textOrangeAA)
                        }
                    }
                    .accessibilityIdentifier("journalLives.ownJournal")

                    self.positionRow(
                        rowID: "journalLives.onYourPhone",
                        title: SourceVocabulary.journalLivesOnYourPhoneTitle,
                        body: SourceVocabulary.journalLivesOnYourPhoneBody,
                        current: false
                    ) {
                        Text(SourceVocabulary.journalLivesComingLater)
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("journalLives.onYourPhone.comingLater")
                    }
                    .foregroundStyle(.secondary)
                } footer: {
                    if !self.appConfig.isPaired {
                        Text(SourceVocabulary.journalLivesCachedLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("journalLives.cachedLine")
                    }
                }
            }
            .accessibilityIdentifier("journalLives.sheet")
            .navigationTitle(SourceVocabulary.journalLivesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        self.isPresented = false
                    }
                }
            }
            .navigationDestination(for: Destination.self) { _ in
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
    }

    private func positionRow<Trailing: View>(
        rowID: String,
        title: String,
        body: String,
        current: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(rowID)

                if current {
                    Text(Image(systemName: "checkmark.circle.fill"))
                        .foregroundStyle(Color.solOrange)
                        .accessibilityLabel("current")
                        .accessibilityIdentifier("\(rowID).current")
                }

                trailing()
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
