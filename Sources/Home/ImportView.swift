// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ImportView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ShareTransferHolder.self) private var shareTransferHolder
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: SourceVocabulary.whatItAddsTitle) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SourceVocabulary.importerWhatItAdds)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: self.appConfig.isPaired))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                SourceDetailBlock(title: "recent") {
                    Text(ImportRecentPresentation.recentText(
                        pendingCount: self.shareTransferHolder.pendingCount,
                        lastDeliveredAt: self.shareTransferHolder.lastUploadAt,
                        failedCount: self.shareTransferHolder.failedCount
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        .navigationTitle(SourceVocabulary.importTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("shell.pane.import")
    }
}
