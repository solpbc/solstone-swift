// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OnThisPhoneView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var result: OnThisPhoneResult = .loadedEmpty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SourceVocabulary.onThisPhoneScope)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                self.content
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(SourceVocabulary.journalDashboardTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            self.result = self.importQueue.onThisPhoneSnapshot()
        }
    }
}

private extension OnThisPhoneView {
    @ViewBuilder
    var content: some View {
        switch self.result {
        case .loaded(let items):
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    NavigationLink {
                        OnThisPhoneItemDetailView(item: item)
                    } label: {
                        OnThisPhoneRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .loadedEmpty:
            Text(SourceVocabulary.onThisPhoneEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed:
            Text(SourceVocabulary.onThisPhoneFailed)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OnThisPhoneRow: View {
    let item: OnThisPhoneItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.item.filename ?? SourceVocabulary.notProvided)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(self.item.contentType ?? SourceVocabulary.notProvided)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: self.symbolName)
                Text(self.item.sendState.label)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(self.stateColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var symbolName: String {
        switch self.item.sendState {
        case .inYourJournal:
            "checkmark.circle"
        case .sending:
            "arrow.up.circle"
        case .savedOnThisPhone:
            "internaldrive"
        case .needsAttention:
            "exclamationmark.triangle"
        }
    }

    private var stateColor: Color {
        switch self.item.sendState {
        case .needsAttention:
            .red
        case .inYourJournal, .sending, .savedOnThisPhone:
            .secondary
        }
    }
}
