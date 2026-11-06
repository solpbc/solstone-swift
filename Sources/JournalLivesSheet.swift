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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        Group {
            if self.appConfig.isPaired {
                List {
                    Section {
                        NavigationLink(value: ShellDestination.pairFlow) {
                            self.positionRow(
                                rowID: "journalLives.ownJournal",
                                title: SourceVocabulary.journalLivesOwnTitle,
                                body: SourceVocabulary.journalLivesOwnBody,
                                current: true
                            ) {
                                Text(SourceVocabulary.journalLivesAction(isPaired: true))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(self.colorScheme == .dark ? Color.primary : Color.textOrangeAA)
                            }
                        }
                        .accessibilityIdentifier("journalLives.ownJournal")
                    }
                    .listRowBackground(Color.deckSurface)
                }
                .scrollContentBackground(.hidden)
            } else {
                // No journal yet: the setup doors, centered in a readable column on iPad.
                ScrollView {
                    JournalSetupRoute {
                        NavigationLink(value: ShellDestination.pairFlow) {
                            JournalSetupPairLabel()
                        }
                        .accessibilityIdentifier("journalLives.ownJournal")
                    }
                    .padding(.horizontal, ShellMetrics.screenMargin)
                    // The iPad pane has room to let the column breathe below its title.
                    .padding(.top, self.horizontalSizeClass == .regular ? 48 : 16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color.deckGround)
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
        let heading = Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(rowID)
        return VStack(alignment: .leading, spacing: 4) {
            if self.dynamicTypeSize.isAccessibilitySize && !current {
                heading
                trailing()
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    heading
                    if current {
                        Text(Image(systemName: "checkmark.circle.fill"))
                            .foregroundStyle(Color.solOrange)
                            .accessibilityLabel("current")
                            .accessibilityIdentifier("\(rowID).current")
                    }
                    trailing()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
