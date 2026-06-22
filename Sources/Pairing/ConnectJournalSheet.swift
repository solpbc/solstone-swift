// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ConnectJournalSheet: View {
    private enum Destination: Hashable {
        case ownJournal
        case hostedJournal
    }

    static let hostedJournalAvailable = false

    @Binding var isPresented: Bool
    @Environment(TunnelManager.self) private var tunnelManager
    @State private var path: [Destination] = []

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

                    if Self.hostedJournalAvailable {
                        NavigationLink(value: Destination.hostedJournal) {
                            self.doorRow(
                                label: SourceVocabulary.connectDoorHostedTitle,
                                subtitle: SourceVocabulary.connectDoorHostedSubtitle,
                                systemImage: "cloud"
                            )
                        }
                        .accessibilityIdentifier("connectJournal.hostedJournal")
                    }
                }
            }
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
                            self.tunnelManager.armOwnerConnectSuccessBanner()
                            self.isPresented = false
                        }
                    )
                case .hostedJournal:
                    EmptyView()
                }
            }
        }
    }

    private func doorRow(label: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.solOrangeAccessible)
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
