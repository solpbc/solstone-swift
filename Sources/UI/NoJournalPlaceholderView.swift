// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct NoJournalPlaceholderView: View {
    enum Kind {
        case today
        case ask

        var bodyText: String {
            switch self {
            case .today:
                "your observations stay on this phone. connect a journal to see your day come together here."
            case .ask:
                "ask draws on your journal. connect one and your questions get answers from your own days."
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .today:
                "placeholder.today"
            case .ask:
                "placeholder.ask"
            }
        }
    }

    let kind: Kind
    @State private var showingConnectJournal = false

    var body: some View {
        VStack(spacing: 18) {
            Text(self.kind.bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .accessibilityIdentifier(self.kind.accessibilityIdentifier)

            Button("connect a journal") {
                self.showingConnectJournal = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sheet(isPresented: self.$showingConnectJournal) {
            ConnectJournalSheet(isPresented: self.$showingConnectJournal)
        }
    }
}
