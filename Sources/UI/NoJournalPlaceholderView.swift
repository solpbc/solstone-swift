// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct NoJournalPlaceholderView: View {
    enum Kind {
        case today
        case ask

        var headline: String? {
            switch self {
            case .today:
                nil
            case .ask:
                SourceVocabulary.askEmptyHeadline
            }
        }

        var systemImage: String? {
            switch self {
            case .today:
                nil
            case .ask:
                SourceVocabulary.askEmptyIconName
            }
        }

        var bodyText: String {
            switch self {
            case .today:
                "your observations stay on this phone. connect a journal to see your day come together here."
            case .ask:
                SourceVocabulary.askEmptyBody
            }
        }

        var buttonText: String {
            switch self {
            case .today:
                "connect a journal"
            case .ask:
                SourceVocabulary.askEmptyButton
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
    let count: Int
    @State private var showingConnectJournal = false

    init(kind: Kind, count: Int = 0) {
        self.kind = kind
        self.count = count
    }

    var body: some View {
        VStack(spacing: 18) {
            if let systemImage = self.kind.systemImage {
                Image(systemName: systemImage)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if let headline = self.kind.headline {
                Text(headline)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            Text(self.kind.bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .accessibilityIdentifier(self.kind.accessibilityIdentifier)

            if self.kind == .ask, self.count > 0 {
                Text(SourceVocabulary.askWaitingObservations(count: self.count))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("placeholder.ask.count")
            }

            Button(self.kind.buttonText) {
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

struct AskNoJournalPlaceholderContainer: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(LocationUploader.self) private var locationUploader
    @State private var count = 0

    var body: some View {
        NoJournalPlaceholderView(kind: .ask, count: self.count)
            .onAppear {
                self.loadCount()
            }
    }
}

private extension AskNoJournalPlaceholderContainer {
    func loadCount() {
        let aggregate = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: self.importQueue,
            observerUploader: self.observerUploader,
            locationUploader: self.locationUploader
        )
        self.count = aggregate.items.count
    }
}
