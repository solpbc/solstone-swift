// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct AskSolPreviewSheet: View {
    @Binding var isPresented: Bool
    @State private var showingConnectJournal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(SourceVocabulary.chatEmptyHeading)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("askPreview.heading")

            Text(SourceVocabulary.chatEmptyBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("askPreview.body")

            VStack(alignment: .leading, spacing: 8) {
                self.seedChip(
                    SourceVocabulary.chatEmptySeed1,
                    id: "askPreview.seed1"
                )
                self.seedChip(
                    SourceVocabulary.chatEmptySeed2,
                    id: "askPreview.seed2"
                )
            }

            Text(SourceVocabulary.askPreviewStateLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("askPreview.stateLine")

            Button {
                self.showingConnectJournal = true
            } label: {
                Text("connect a journal")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("askPreview.connect")

            Button("not yet") {
                self.isPresented = false
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("askPreview.notYet")
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("askPreview.sheet")
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: self.$showingConnectJournal) {
            ConnectJournalSheet(isPresented: self.$showingConnectJournal)
        }
    }

    private func seedChip(_ text: String, id: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier(id)
    }
}
