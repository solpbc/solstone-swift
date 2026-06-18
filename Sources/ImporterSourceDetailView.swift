// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ImporterSourceDetailView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteResult: DeleteShareSourceResult?

    let source: Source

    init(source: Source) {
        self.source = source
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: "always on") {
                    Text(SourceVocabulary.shareAlwaysOnExplainer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SourceDetailBlock(title: "what it adds") {
                    Text(SourceVocabulary.importerWhatItAdds)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SourceDetailBlock(title: "recent") {
                    self.recentBlock
                }

                SourceDetailBlock(title: SourceVocabulary.onThisPhone) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SourceVocabulary.onThisPhoneScope)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        NavigationLink(SourceVocabulary.onThisPhone) {
                            OnThisPhoneView()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(SourceVocabulary.onThisPhone)
                        .accessibilityHint("Shows what you've sent to your journal.")
                    }
                }

                SourceDetailBlock(title: SourceVocabulary.delete) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(SourceVocabulary.deleteConfirmButton, role: .destructive) {
                            self.showingDeleteConfirm = true
                        }
                            .buttonStyle(.bordered)
                            .disabled(self.isDeleting)
                            .accessibilityHint("Removes everything share sheet added to your journal.")

                        self.deleteResultBlock
                    }
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(self.source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert(SourceVocabulary.deleteConfirmButton, isPresented: self.$showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(SourceVocabulary.deleteConfirmButton, role: .destructive) {
                Task {
                    await self.runDelete()
                }
            }
        } message: {
            Text(SourceVocabulary.deleteConfirmBody)
        }
    }
}

private extension ImporterSourceDetailView {
    @ViewBuilder
    var recentBlock: some View {
        if self.importQueue.pendingCount > 0 {
            Text(SourceVocabulary.shareSendingProgress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if self.importQueue.lastDeliveredAt != nil {
            Text(SourceVocabulary.shareDeliveredProgress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if self.importQueue.failedCount > 0 {
            Text(SourceVocabulary.needsAttentionSubtext)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text(SourceVocabulary.recentEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var deleteResultBlock: some View {
        if let deleteResult {
            switch deleteResult {
            case .confirmed(let receipt, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text(SourceVocabulary.deleteReceiptHeadline(originals: receipt.removed.originals))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(deleteResult.notRemovedIssues, id: \.self) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.what)
                            Text(issue.plainReason)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(deleteResult.notConfirmedIssues, id: \.self) { issue in
                        Text(issue.plainReason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            case .notConfirmed, .unreachable:
                Text(SourceVocabulary.deleteJournalUnreachableLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    func runDelete() async {
        self.isDeleting = true
        defer {
            self.isDeleting = false
        }

        let result = await self.importQueue.deleteShareSource()
        self.deleteResult = result
    }
}
