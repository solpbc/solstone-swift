// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct DiagnosticsView: View {
    @Environment(DiagnosticLog.self) private var log
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(OmiUploaderHolder.self) private var omiUploaderHolder
    @Environment(ImportQueue.self) private var importQueue
    @Environment(LocationUploader.self) private var locationUploader
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(BrainStatusMonitor.self) private var brainStatusMonitor

    @State private var enabledCategories: Set<DiagnosticCategory> = Set(DiagnosticCategory.allCases)
    @State private var expandedEventID: UUID?
    @State private var justCopied = false
    @State private var copyTask: Task<Void, Never>?
    @State private var diagnosticsExportURL: URL?
    @State private var problemsOnly = false
    @State private var isRetrying = false

    private var failedTotal: Int {
        uploadFailedTotal(
            observer: self.observerUploader,
            omi: self.omiUploaderHolder,
            importQueue: self.importQueue,
            location: self.locationUploader
        )
    }

    private var failedSegmentPresentation: FailedSegmentPresentation? {
        FailedSegmentSection.presentation(
            failedTotal: self.failedTotal,
            isConnected: self.tunnelManager.state.isConnected
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
        let aggregate = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: self.importQueue,
            observerUploader: self.observerUploader,
            omiUploader: self.omiUploaderHolder.uploader,
            locationUploader: self.locationUploader
        )
        let migration = onThisPhoneMigration(snapshot: aggregate)

        List {
            self.lifecycleSection(migration: migration)
            if let failedSegmentPresentation {
                self.failedSegmentSection(failedSegmentPresentation)
            }
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
            self.refreshDiagnosticsExport()
        }
        .onChange(of: self.log.events.count) {
            self.refreshDiagnosticsExport()
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
        Section(SourceVocabulary.onThisPhone) {
            LabeledContent(SourceVocabulary.migrationStageOnThisPhone, value: "\(migration.onThisPhone)")
                .accessibilityIdentifier("diagnostics.lifecycle.onThisPhone")
            LabeledContent(SourceVocabulary.migrationStageOnItsWay, value: "\(migration.onItsWay)")
                .accessibilityIdentifier("diagnostics.lifecycle.onItsWay")
            LabeledContent(SourceVocabulary.migrationStageInYourJournal, value: "\(migration.inYourJournal)")
                .accessibilityIdentifier("diagnostics.lifecycle.inYourJournal")
            LabeledContent(SourceVocabulary.needsAttention, value: "\(migration.needsAttention)")
                .accessibilityIdentifier("diagnostics.lifecycle.needsAttention")
        }
        .accessibilityIdentifier("diagnostics.lifecycle")
    }

    private func failedSegmentSection(_ presentation: FailedSegmentPresentation) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(presentation.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(presentation.subtext)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if presentation.showsButton {
                    Button {
                        Task { @MainActor in
                            await self.retryFailedSegments()
                        }
                    } label: {
                        Text(self.isRetrying ? "trying…" : "try now")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.isRetrying)
                    .accessibilityLabel("retry \(self.failedTotal) failed segments now")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @MainActor
    private func retryFailedSegments() async {
        guard !self.isRetrying else { return }
        let failedTotal = self.failedTotal
        self.isRetrying = true
        defer {
            self.isRetrying = false
        }

        self.log.append(
            category: .upload,
            severity: .info,
            message: "manual retry of failed segments requested",
            detail: "count=\(failedTotal)"
        )
        if UserSettings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        await self.observerUploader.retryFailed()
        await self.omiUploaderHolder.uploader.retryFailed()
        await self.importQueue.retryFailed()
        await self.locationUploader.retryFailed()
    }

    private func copySnapshot() {
        let text = self.log.snapshot(
            tunnel: self.tunnelManager,
            voice: self.voiceManager,
            brain: self.brainStatusMonitor
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

    private func refreshDiagnosticsExport() {
        self.diagnosticsExportURL = self.log.exportFileURL(
            tunnel: self.tunnelManager,
            voice: self.voiceManager,
            brain: self.brainStatusMonitor
        )
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
        case .voice: "mic"
        case .network: "wifi"
        case .upload: "arrow.up.circle"
        case .brain: "brain"
        }
    }

    private var normalCategoryColor: Color {
        switch self.event.category {
        case .tunnel: .orange
        case .voice: .blue
        case .network: .gray
        case .upload: .green
        case .brain: .purple
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
