#if os(iOS)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import os

private let watchSourceLog = Logger(subsystem: "app.solstone.swift", category: "watch")

nonisolated struct WatchDiagnosticsExport: Transferable, Equatable, Sendable {
    let text: String
    let filename: String

    init(summary: WatchPipelineSummary) {
        self.text = summary.diagnosticsExportText
        self.filename = SourceVocabulary.watchDiagnosticsExportFileName
    }

    nonisolated static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            let url = try WatchDiagnosticsExport.writeTransferFile(text: export.text, into: WatchDiagnosticsExport.exportTempRoot)
            return SentTransferredFile(url)
        }
        .suggestedFileName { export in
            export.filename
        }
    }

    /// Single source of truth for the per-transfer temp namespace. The sweep is scoped
    /// to this directory and can never touch unrelated temp contents.
    nonisolated static let exportTempDirectoryName = "watch-diagnostics-export"

    /// Upper bound on retained per-transfer subdirectories. Keeping the newest K leaves
    /// comfortable margin for an in-flight transfer's copy while keeping the temp area bounded.
    nonisolated static let maxRetainedExportDirectories = 8

    nonisolated static var exportTempRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(exportTempDirectoryName, isDirectory: true)
    }

    /// Writes `text` to a fresh per-transfer subdirectory (unique UUID) whose file basename
    /// is the pinned diagnostics filename, sweeps stale siblings to keep `root` bounded, and
    /// returns the written URL. Throwing propagates to the share sheet — no fallback.
    nonisolated static func writeTransferFile(text: String, into root: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            SourceVocabulary.watchDiagnosticsExportFileName,
            isDirectory: false
        )
        try Data(text.utf8).write(to: url, options: [.atomic])
        sweepStaleExportDirectories(in: root, keeping: directory)
        return url
    }

    /// Deletes older per-transfer subdirectories, retaining the `maxRetainedExportDirectories`
    /// most-recently-created ones and always preserving `keep`. Best-effort: never throws — a
    /// failed unlink must not fail an export.
    nonisolated static func sweepStaleExportDirectories(in root: URL, keeping keep: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let newestFirst = entries.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        let keepPath = keep.standardizedFileURL.path
        for (index, entry) in newestFirst.enumerated() {
            if index < maxRetainedExportDirectories || entry.standardizedFileURL.path == keepPath {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }
}

struct WatchSourceDetailView: View {
    // KILL-LIST-EXEMPT:BEGIN
    @Environment(WatchLink.self) private var watchLink
    @Environment(WatchRelayReceiver.self) private var receiver: WatchRelayReceiver?
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(WatchSegmentLedger.self) private var watchSegmentLedger
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @State private var now = Date()

    var pipelineInput: WatchPipelineInput {
        WatchPipelineInput(
            now: self.now,
            watchStatus: self.watchLink.watchStatus,
            lifetimeReceived: self.watchSegmentLedger.lifetimeReceived,
            lifetimeHanded: self.watchSegmentLedger.lifetimeHanded,
            nonTerminalCount: self.watchSegmentLedger.nonTerminalCount,
            lastHandedAt: self.watchSegmentLedger.lastHandedAt,
            oldestNonTerminalReceivedAt: self.watchSegmentLedger.oldestNonTerminalReceivedAt,
            lastLedgerError: self.watchSegmentLedger.lastLedgerError,
            pendingCount: self.watchUploaderHolder.pendingCount,
            failedCount: self.watchUploaderHolder.failedCount,
            inFlightCount: self.watchUploaderHolder.inFlightCount,
            lastUploadAt: self.watchUploaderHolder.lastUploadAt,
            lastUploadError: self.watchUploaderHolder.lastError,
            lastReceivedAt: self.receiver?.lastReceivedAt,
            lastStagingError: self.receiver?.lastStagingError,
            isPaired: self.watchLink.isPaired,
            isWatchAppInstalled: self.watchLink.isWatchAppInstalled,
            activationState: self.watchLink.activationState,
            isJournalReachable: isJournalReachable(self.connectionSyncModel.status)
        )
    }
    // KILL-LIST-EXEMPT:END

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
        let summary = self.summary
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(summary.pipelineRows) { row in
                LabeledContent(row.label, value: row.value)
            }
            self.stuckNoticeBlock(summary.stuck)
        }
        .font(.subheadline)
    }

    var diagnosticsBlock: some View {
        let summary = self.summary
        let rows = summary.diagnosticsRows
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(SourceVocabulary.watchTechnicalDetailTitle) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            }

            ShareLink(
                item: WatchDiagnosticsExport(summary: summary),
                preview: SharePreview(SourceVocabulary.watchDiagnosticsExportFileName)
            ) {
                Label(SourceVocabulary.watchShareDiagnosticsLabel, systemImage: "square.and.arrow.up")
            }
            .frame(minHeight: 44)
            .accessibilityHint(SourceVocabulary.watchShareDiagnosticsHint)
        }
        .font(.subheadline)
    }

    var installState: WatchInstallState {
        let input = self.pipelineInput
        return watchInstallState(
            isSupported: self.watchLink.isSupported,
            isPaired: input.isPaired,
            isWatchAppInstalled: input.isWatchAppInstalled,
            activationState: input.activationState,
            now: input.now,
            lastReceivedAt: input.lastReceivedAt
        )
    }

    var recordingStatus: WatchRecordingStatus {
        let input = self.pipelineInput
        return watchRecordingStatus(
            context: input.watchStatus,
            now: input.now,
            lastReceivedAt: input.lastReceivedAt
        )
    }

    var watchPresentation: PhoneWatchSourcePresentation {
        phoneWatchSourcePresentation(
            install: self.installState,
            recordingStatus: self.recordingStatus
        )
    }

    var summary: WatchPipelineSummary {
        WatchPipelineReducer.reduce(self.pipelineInput)
    }

    @ViewBuilder
    func stuckNoticeBlock(_ stuck: WatchPipelineStuck) -> some View {
        if let notice = WatchSourceDetailPresentation.stuckNotice(for: stuck) {
            Label(notice.reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.solOrange)
                .accessibilityIdentifier("watch.pipelineStuckNotice")
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
