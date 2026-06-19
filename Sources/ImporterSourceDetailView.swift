// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ImporterSourceDetailView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(self.source.displayName)
        .navigationBarTitleDisplayMode(.inline)
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

}
