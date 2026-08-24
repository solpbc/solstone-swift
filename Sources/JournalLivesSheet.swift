// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct JournalLivesSheet: View {
    @Binding var isPresented: Bool
    @Environment(TunnelManager.self) private var tunnelManager
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: self.$path) {
            JournalLivesPane()
                .navigationDestination(for: ShellDestination.self) { destination in
                    switch destination {
                    case .pairFlow:
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
                    default:
                        ShellDestinationView(destination: destination)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            self.isPresented = false
                        }
                    }
                }
        }
        .accessibilityIdentifier("journalLives.sheet")
    }
}

struct JournalLivesPane: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(\.colorScheme) private var colorScheme
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        List {
            Section {
                Text(SourceVocabulary.journalLivesPromise)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("journalLives.promise")
            }

            Section {
                NavigationLink(value: ShellDestination.pairFlow) {
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
        .navigationTitle(SourceVocabulary.journalLivesTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(SourceVocabulary.journalLivesTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.pane.journalSetup.heading")
                    .accessibilityFocused(self.$headingFocused)
            }
        }
        .accessibilityIdentifier("shell.pane.journalSetup")
        .onAppear { self.headingFocused = true }
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
