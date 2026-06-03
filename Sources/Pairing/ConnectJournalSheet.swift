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
    @State private var path: [Destination] = []

    var body: some View {
        NavigationStack(path: self.$path) {
            List {
                Section {
                    Text("your observations are kept on this phone. connect a journal and everything gathered so far flows in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink(value: Destination.ownJournal) {
                        self.doorRow(
                            label: "your own journal",
                            subtitle: "pair this phone to a solstone running on your computer.",
                            systemImage: "desktopcomputer"
                        )
                    }
                    .accessibilityIdentifier("connectJournal.ownJournal")

                    if Self.hostedJournalAvailable {
                        NavigationLink(value: Destination.hostedJournal) {
                            self.doorRow(
                                label: "hosted journal",
                                subtitle: "connect to a solstone journal hosted for you.",
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
