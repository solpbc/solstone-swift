#if os(iOS)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import os

private let watchSourceLog = Logger(subsystem: "app.solstone.swift", category: "watch")

struct WatchSourceDetailView: View {
    @Environment(WatchLink.self) private var watchLink
    @Environment(WatchRelayReceiver.self) private var receiver: WatchRelayReceiver?
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @State private var diagnosticsExportURL: URL?
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.content
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(SourceVocabulary.watchSourceDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            self.refreshDiagnosticsExport()
        }
        .task {
            await self.refreshNowPeriodically()
        }
    }
}

private extension WatchSourceDetailView {
    @ViewBuilder
    var content: some View {
        SourceDetailBlock(title: SourceVocabulary.watchStateBlockTitle) {
            self.stateBlock
        }

        SourceDetailBlock(title: SourceVocabulary.watchDeviceBlockTitle) {
            self.watchBlock
        }

        SourceDetailBlock(title: SourceVocabulary.watchDiagnosticsBlockTitle) {
            self.diagnosticsBlock
        }
    }

    var stateBlock: some View {
        let presentation = self.watchPresentation
        return VStack(alignment: .leading, spacing: 12) {
            self.stateLine

            Text(presentation.subtext)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let attention = presentation.attention {
                Text(attention.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let affordance = WatchSourceDetailPresentation.installAffordance(install: self.installState) {
                Button {
                    self.openURL(URL(string: "itms-watchs://")!) { accepted in
                        if !accepted {
                            watchSourceLog.info("watch install deep link not accepted")
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(affordance.title)
                            .font(.subheadline.weight(.semibold))
                        Text(affordance.instruction)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch.installAffordance")
            }
        }
    }

    var stateLine: some View {
        let sourceState = self.watchPresentation.state
        return HStack(spacing: 8) {
            Image(systemName: sourceState.symbol)
            Text(sourceState.label)
        }
        .font(.headline)
    }

    var watchBlock: some View {
        let rows = WatchSourceDetailPresentation.syncRows(summary: self.syncSummary, now: self.now)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                LabeledContent(row.label, value: row.value)
            }
        }
        .font(.subheadline)
    }

    var diagnosticsBlock: some View {
        let rows = self.diagnosticsRows
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(SourceVocabulary.watchTechnicalDetailTitle) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            }

            if let diagnosticsExportURL {
                ShareLink(item: diagnosticsExportURL) {
                    Label(SourceVocabulary.watchShareDiagnosticsLabel, systemImage: "square.and.arrow.up")
                }
                .frame(minHeight: 44)
                .accessibilityHint(SourceVocabulary.watchShareDiagnosticsHint)
            } else {
                Button {
                    self.refreshDiagnosticsExport()
                } label: {
                    Label(SourceVocabulary.watchShareDiagnosticsLabel, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint(SourceVocabulary.watchPrepareDiagnosticsHint)
            }
        }
        .font(.subheadline)
    }

    var installState: WatchInstallState {
        watchInstallState(
            isSupported: self.watchLink.isSupported,
            isPaired: self.watchLink.isPaired,
            isWatchAppInstalled: self.watchLink.isWatchAppInstalled,
            activationState: self.watchLink.activationState,
            now: self.now,
            lastReceivedAt: self.watchLink.lastReceivedAt
        )
    }

    var recordingStatus: WatchRecordingStatus {
        watchRecordingStatus(
            context: self.watchLink.watchStatus,
            now: self.now,
            lastReceivedAt: self.watchLink.lastReceivedAt
        )
    }

    var watchPresentation: PhoneWatchSourcePresentation {
        phoneWatchSourcePresentation(
            install: self.installState,
            recordingStatus: self.recordingStatus
        )
    }

    var syncSummary: WatchSourceSyncSummary {
        WatchSourceDetailPresentation.syncSummary(
            received: self.receiver?.receivedCount ?? 0,
            pending: self.watchUploaderHolder.pendingCount,
            failed: self.watchUploaderHolder.failedCount,
            lastUploadAt: self.watchUploaderHolder.lastUploadAt
        )
    }

    var diagnosticsRows: [WatchSourceDetailRow] {
        WatchSourceDetailPresentation.diagnosticsRows(
            activationState: self.watchLink.activationState,
            isPaired: self.watchLink.isPaired,
            isWatchAppInstalled: self.watchLink.isWatchAppInstalled,
            watchStatus: self.watchLink.watchStatus,
            lastReceivedAt: self.receiver?.lastReceivedAt,
            lastStagingError: self.receiver?.lastStagingError,
            lastUploadAt: self.watchUploaderHolder.lastUploadAt,
            lastUploadError: self.watchUploaderHolder.lastError,
            now: self.now
        )
    }

    func refreshDiagnosticsExport() {
        let text = WatchSourceDetailPresentation.diagnosticsExportText(
            syncRows: WatchSourceDetailPresentation.syncRows(summary: self.syncSummary, now: self.now),
            diagnosticsRows: self.diagnosticsRows
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(SourceVocabulary.watchDiagnosticsExportFileName, isDirectory: false)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            self.diagnosticsExportURL = url
        } catch {
            self.diagnosticsExportURL = nil
        }
    }

    func refreshNowPeriodically() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else {
                return
            }
            self.now = Date()
        }
    }
}
#endif
