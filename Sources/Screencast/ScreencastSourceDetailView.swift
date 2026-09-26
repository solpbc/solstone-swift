// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ScreencastSourceDetailView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingScreencastPrimer = false
    @State private var recentResult: ObserverManifestResult?
    @State private var recentPort: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: SourceVocabulary.screencastStateTitle) {
                    self.stateBlock
                }

                SourceDetailBlock(title: SourceVocabulary.screencastRecentTitle) {
                    ObserverManifestRecentList(result: self.recentResult, isJournalPaired: self.appConfig.isPaired)
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
        .task(id: self.recentKey) {
            await self.loadRecent()
        }
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

    var recentKey: LinkedDeviceIngestRecentKey {
        LinkedDeviceIngestRecentKey(
            port: self.tunnelManager.activeConnection?.port,
            deliveredCount: self.mobileSegmentTransferHolder.deliveredCount
        )
    }

    func loadRecent() async {
        // A delivery refreshes the list in place; only a new connection starts over with a spinner.
        let port = self.tunnelManager.activeConnection?.port
        if port != self.recentPort {
            self.recentResult = nil
        }
        self.recentPort = port
        let tunnelManager = self.tunnelManager
        let reconciler = LinkedDeviceIngestReconciler(activeLocalPort: { tunnelManager.activeConnection?.port })
        let result = await reconciler.reconcileObserverManifest(
            day: LinkedDeviceIngestViewMapper.dayString(for: Date()),
            fileName: ObserverAudioTransferEnqueuer.screencastPart().filename
        )
        // A newer read (a delivery, or a connection change) cancelled this one: its answer is
        // stale, and writing it would show a failure the newer read doesn't have.
        guard !Task.isCancelled else { return }
        self.recentResult = result
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
