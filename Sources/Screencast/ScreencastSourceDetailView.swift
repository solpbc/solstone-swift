// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ScreencastSourceDetailView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: SourceVocabulary.screencastStateTitle) {
                    self.stateBlock
                }

                SourceDetailBlock(title: SourceVocabulary.screencastRecentTitle) {
                    Text(SourceVocabulary.recentEmpty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SourceDetailBlock(title: SourceVocabulary.screencastDeliveryTitle) {
                    self.deliveryBlock
                }

                SourceHomeTileControl(sourceID: "screencast")
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(SourceVocabulary.screencastDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension ScreencastSourceDetailView {
    var stateBlock: some View {
        let source = screencastSourcePresentation(
            managerState: self.screencastManager.state,
            isJournalPaired: self.appConfig.isPaired
        )

        return VStack(alignment: .leading, spacing: 12) {
            SourceDetailVerdictLine(state: source.state)
            SourceDetailReasonLine(message: source.attention?.message)

            Text(self.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ScreencastPickerView {
                    self.screencastManager.beginStarting()
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel(SourceVocabulary.screencastOpenSystemSheet)

                Text(SourceVocabulary.screencastOpenSystemSheet)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(minHeight: 44)
        }
    }

    var deliveryBlock: some View {
        let summary = self.mobileSegmentTransferHolder.summary(for: .screencast)
        let presentation = LocationDetailPresentation.deliverySummary(
            pending: summary.pendingCount,
            failed: summary.failedCount
        )

        return Text(presentation.line)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    var statusText: String {
        switch self.screencastManager.state {
        case .off:
            SourceVocabulary.screencastReadyText
        case .starting:
            SourceVocabulary.screencastStartingText
        case .active:
            SourceVocabulary.screencastActiveText
        case .needsAttention(let attention):
            screencastAttentionMessage(attention)
        case .unavailable:
            SourceVocabulary.screencastUnavailableText
        }
    }
}
