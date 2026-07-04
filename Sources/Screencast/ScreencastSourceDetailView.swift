// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ScreencastSourceDetailView: View {
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(MobileSegmentUploader.self) private var mobileSegmentUploader
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
            managerState: self.screencastManager.state
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: source.state.symbol)
                Text(source.state.label)
            }
            .font(.headline)

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

            if let attention = source.attention {
                Text(attention.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var deliveryBlock: some View {
        let summary = self.mobileSegmentUploader.summary(for: .screencast)
        let presentation = LocationDetailPresentation.deliverySummary(
            pending: summary.pendingCount,
            failed: summary.failedCount,
            lastUploadAt: summary.lastUploadAt
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text(presentation.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if presentation.showsRetry {
                Button(SourceVocabulary.retry) {
                    Task {
                        await self.mobileSegmentUploader.retryFailed(respectingCooldown: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
            }
        }
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
