// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let diagnosticsUploadLog = Logger(subsystem: "app.solstone.swift", category: "upload")

private struct FailedReconcileKey: Equatable, Sendable {
    let rawFailed: Int
    let failedRepresented: Int
}

struct DiagnosticsView: View {
    @Environment(DiagnosticLog.self) private var log
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(MobileSegmentUploader.self) private var mobileSegmentUploader
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(OmiUploaderHolder.self) private var omiUploaderHolder
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(ShareTransferHolder.self) private var shareTransferHolder

    @State private var enabledCategories: Set<DiagnosticCategory> = Set(DiagnosticCategory.allCases)
    @State private var expandedEventID: UUID?
    @State private var justCopied = false
    @State private var copyTask: Task<Void, Never>?
    @State private var diagnosticsExportURL: URL?
    @State private var problemsOnly = false
    @State private var lastSynced: Date?
    @State private var lastReconcileKey: FailedReconcileKey?
    @State private var lifecycleMigration = OnThisPhoneMigration(
        onThisPhone: 0,
        needsAttention: 0
    )

    private var failedTotal: Int {
        uploadFailedTotal(
            mobileSegment: self.mobileSegmentTransferHolder,
            omi: self.omiUploaderHolder,
            watch: self.watchUploaderHolder,
            share: self.shareTransferHolder
        )
    }

    private var filteredEvents: [DiagnosticEvent] {
        Array(self.log.events.filter { event in
            DiagnosticsEventFilter.matches(
                event,
                categories: self.enabledCategories,
                problemsOnly: self.problemsOnly
            )
        }.reversed())
    }

    var body: some View {
        List {
            self.lifecycleSection(migration: self.lifecycleMigration)
            self.eventRows
        }
        .navigationTitle("diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        self.copySnapshot()
                    } label: {
                        if self.justCopied {
                            Label("copied", systemImage: "checkmark")
                        } else {
                            Label("copy snapshot", systemImage: "doc.on.doc")
                        }
                    }

                    if let diagnosticsExportURL {
                        ShareLink(item: diagnosticsExportURL) {
                            Label("export", systemImage: "square.and.arrow.up")
                        }
                    }

                    Divider()

                    Button {
                        self.problemsOnly.toggle()
                    } label: {
                        Label(
                            "problems only",
                            systemImage: self.problemsOnly ? "checkmark.circle.fill" : "circle"
                        )
                    }

                    Divider()

                    ForEach(DiagnosticCategory.allCases, id: \.self) { category in
                        Button {
                            if self.enabledCategories.contains(category) {
                                self.enabledCategories.remove(category)
                            } else {
                                self.enabledCategories.insert(category)
                            }
                        } label: {
                            Label(
                                category.rawValue,
                                systemImage: self.enabledCategories.contains(category) ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("filter and actions")
            }
        }
        .onAppear {
            Task { await self.refreshDiagnosticsExport() }
        }
        .onChange(of: self.log.events.count) {
            Task { await self.refreshDiagnosticsExport() }
        }
        .task {
            await self.refreshLifecycle()
        }
        .onDisappear {
            self.copyTask?.cancel()
        }
    }

    @ViewBuilder
    private var eventRows: some View {
        if self.log.events.isEmpty {
            Section {
                self.emptyEventsView
            }
        } else {
            ForEach(self.filteredEvents) { event in
                self.eventRow(event)
            }
        }
    }

    private var emptyEventsView: some View {
        ContentUnavailableView {
            Label("no events yet", systemImage: "clock")
        } description: {
            Text("they'll appear as things happen.")
        }
    }

    private func eventRow(_ event: DiagnosticEvent) -> some View {
        EventRow(
            event: event,
            isExpanded: self.expandedEventID == event.id,
            onTap: {
                withAnimation {
                    if self.expandedEventID == event.id {
                        self.expandedEventID = nil
                    } else {
                        self.expandedEventID = event.id
                    }
                }
            }
        )
    }

    private func lifecycleSection(migration: OnThisPhoneMigration) -> some View {
        return Section(SourceVocabulary.onThisPhone) {
            LabeledContent(SourceVocabulary.waitingToSync, value: "\(migration.backlog)")
                .accessibilityIdentifier("diagnostics.lifecycle.waitingToSync")
            LabeledContent(
                SourceVocabulary.yourJournalSection,
                value: self.connectionSyncModel.status.statusLine
            )
            .accessibilityIdentifier("diagnostics.lifecycle.yourJournal")
            LabeledContent(SourceVocabulary.lastSyncedLabel, value: self.lastSyncedValue)
                .accessibilityIdentifier("diagnostics.lifecycle.lastSynced")
        }
        .accessibilityIdentifier("diagnostics.lifecycle")
    }

    private var lastSyncedValue: String {
        guard let lastSynced = self.lastSynced else { return "—" }
        return SourceVocabulary.probeRelativeLabel(secondsAgo: Date().timeIntervalSince(lastSynced))
    }

    private func copySnapshot() {
        let text = self.log.snapshot(
            tunnel: self.tunnelManager
        )
        UIPasteboard.general.string = text
        if UserSettings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        self.copyTask?.cancel()
        withAnimation(.easeInOut) {
            self.justCopied = true
        }
        self.copyTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                withAnimation(.easeInOut) {
                    self.justCopied = false
                }
            }
        }
    }

    private func refreshDiagnosticsExport() async {
        let launchCaptureRoot = (try? AppGroupContainer.rootURL())?.appendingPathComponent(
            OmiLaunchCaptureFormat.rootDirectoryName,
            isDirectory: true
        )
        let syncState = await syncStateSummaryLines(
            mobileSegment: self.mobileSegmentTransferHolder,
            omi: self.omiUploaderHolder,
            watch: self.watchUploaderHolder,
            share: self.shareTransferHolder,
            transferEngine: self.omiUploaderHolder.transferEngine,
            launchCaptureRootURL: launchCaptureRoot
        )
        self.diagnosticsExportURL = self.log.exportFileURL(
            tunnel: self.tunnelManager,
            syncState: syncState
        )
    }

    private func refreshLifecycle() async {
        while !Task.isCancelled {
            let snapshot = await OnThisPhoneSnapshotAggregator.snapshot(
                share: self.shareTransferHolder,
                mobileSegmentUploader: self.mobileSegmentUploader,
                transferEngine: self.omiUploaderHolder.transferEngine
            )
            let migration = onThisPhoneMigration(snapshot: snapshot)
            self.lifecycleMigration = migration
            let rawFailed = self.failedTotal
            if rawFailed > migration.failedRepresented {
                let key = FailedReconcileKey(
                    rawFailed: rawFailed,
                    failedRepresented: migration.failedRepresented
                )
                if self.lastReconcileKey != key {
                    let delta = rawFailed - migration.failedRepresented
                    diagnosticsUploadLog.info("on-this-phone failed count mismatch raw=\(rawFailed, privacy: .public) represented=\(migration.failedRepresented, privacy: .public) delta=\(delta, privacy: .public)")
                    self.lastReconcileKey = key
                }
            } else {
                self.lastReconcileKey = nil
            }
            self.lastSynced = lastSyncedAt(
                mobileSegment: self.mobileSegmentTransferHolder,
                omi: self.omiUploaderHolder,
                watch: self.watchUploaderHolder,
                share: self.shareTransferHolder
            )
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

private struct EventRow: View {
    let event: DiagnosticEvent
    let isExpanded: Bool
    let onTap: () -> Void

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.event.timestamp, relativeTo: Date())
    }

    private var categoryIconName: String {
        switch self.event.category {
        case .tunnel: "antenna.radiowaves.left.and.right"
        case .network: "wifi"
        case .upload: "arrow.up.circle"
        case .journal: "book.pages"
        case .diagnostics: "doc.text.magnifyingglass"
        }
    }

    private var normalCategoryColor: Color {
        switch self.event.category {
        case .tunnel: .orange
        case .network: .gray
        case .upload: .green
        case .journal: .blue
        case .diagnostics: .teal
        }
    }

    private var iconTint: Color {
        switch self.event.severity.rowEmphasis {
        case .normal:
            self.normalCategoryColor
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private var severityText: String {
        switch self.event.severity {
        case .info:
            "info"
        case .warning:
            "warning"
        case .error:
            "error"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: self.categoryIconName)
                    .foregroundStyle(self.iconTint)
                    .frame(width: 20)
                Text(self.event.message)
                    .font(.subheadline)
                    .lineLimit(self.isExpanded ? nil : 1)
                Spacer()
                Text(self.relativeTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.event.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("severity: \(self.severityText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let detail = self.event.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: self.onTap)
        .accessibilityLabel("\(self.event.category.rawValue): \(self.event.message), \(self.relativeTime)")
        .accessibilityHint(self.isExpanded ? "tap to collapse" : "tap to expand details")
    }
}
