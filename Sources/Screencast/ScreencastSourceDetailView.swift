// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ScreencastSourceDetailView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingScreencastPrimer = false

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
        .sheet(isPresented: self.$showingScreencastPrimer) {
            ScreencastPrimerSheet()
        }
        .navigationTitle(SourceVocabulary.screencastDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension ScreencastSourceDetailView {
    var stateBlock: some View {
        let source = screencastSourcePresentation(
            managerState: self.screencastManager.state,
            isJournalPaired: self.appConfig.isPaired,
            enrolled: self.screencastManager.isEnrolled,
            systemEndedAt: self.screencastManager.systemEndedAt
        )
        let buttonTitle = SourceVocabulary.screencastActionTitle(state: self.screencastManager.state)

        return VStack(alignment: .leading, spacing: 12) {
            SourceDetailVerdictLine(state: source.state)
            SourceDetailReasonLine(message: source.attention?.message)

            Text(self.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(buttonTitle) {
                self.showingScreencastPrimer = true
            }
            .buttonStyle(.bordered)
            .tint(.solOrange)
            .frame(minHeight: 44)
            .accessibilityIdentifier("source.screencast.start")
        }
    }

    var deliveryBlock: some View {
        let summary = self.mobileSegmentTransferHolder.summary(for: .screencast)
        let presentation = ScreencastDetailPresentation.deliverySummary(
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
            if let systemEndedAt = self.screencastManager.systemEndedAt,
               Date().timeIntervalSince(systemEndedAt) <= ScreencastManager.systemEndedVisibleWindowSeconds {
                SourceVocabulary.screencastSystemEndedSubtext
            } else {
                SourceVocabulary.screencastReadyText
            }
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
