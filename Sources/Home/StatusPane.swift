// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct StatusPane: View {
    let presentation: ShellPanePresentation

    @Environment(AppConfig.self) private var appConfig
    @Environment(ShellStatusContext.self) private var shellStatusContext
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @Environment(ProblemReportsManager.self) private var problemReportsManager
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(OmiUploaderHolder.self) private var omiUploaderHolder
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(ShareTransferHolder.self) private var shareTransferHolder
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var justCopiedSnapshot = false
    @State private var snapshotCopyTask: Task<Void, Never>?
    @State private var isProbing = false
    @State private var probeCheckedAt: Date?
    @State private var probeAlive = false
    @State private var probeMilliseconds = 0
    @State private var transferRate: Double = 0

    private var headingString: String { SourceVocabulary.statusTitle }

    private var serverHost: String {
        self.appConfig.host
    }

    private var probeDisplay: String? {
        guard let checkedAt = self.probeCheckedAt else { return nil }
        let secondsAgo = Date().timeIntervalSince(checkedAt)
        return SourceVocabulary.probeChecked(
            alive: self.probeAlive,
            milliseconds: self.probeMilliseconds,
            relative: SourceVocabulary.probeRelativeLabel(secondsAgo: secondsAgo)
        )
    }

    private var probeDisplayColor: Color {
        self.probeAlive ? .green : .orange
    }

    /// What the status view leads with, per the shell contract: the count, then what
    /// is happening to it. The pane had been opening straight into `your journal` and
    /// its connection facts — the one number an owner opens this view to read was not
    /// on it at all.
    ///
    /// ⛔ Caught up is stated in words. A zero is not the same claim as "all caught
    /// up", and rendering `0` where a count goes invites reading it as a failure.
    @ViewBuilder
    private var leadSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                if self.waitingTotal > 0 {
                    Text("\(self.waitingTotal)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(SourceVocabulary.waitingToSync)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        HomeStatusDot(state: self.pillState)
                        Text(self.leadStatusLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(self.leadStatusColor)
                    }
                    .padding(.top, 8)
                } else {
                    // Caught up says it once. The connection fact lives one section
                    // down under `your journal`; repeating `connected` here put the
                    // same word on screen twice, eight points apart.
                    HStack(spacing: 8) {
                        HomeStatusDot(state: self.pillState)
                        Text(self.caughtUpHeadline)
                            .font(ShellFont.display(26, relativeTo: .title))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("shell.pane.status.lead")
        }
    }

    /// Every waiting row opens that source, so the breakdown is a way in rather than
    /// a dead end. Only sources actually holding something appear.
    @ViewBuilder
    private var whatIsWaitingSection: some View {
        if !self.waitingRows.isEmpty {
            Section(SourceVocabulary.whatIsWaitingSection) {
                ForEach(self.waitingRows, id: \.route.id) { row in
                    NavigationLink(value: ShellDestination.source(row.route)) {
                        HStack(spacing: 14) {
                            Image(systemName: row.kind.glyph)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.solOrangeAdaptive)
                                .frame(width: 26)
                                .accessibilityHidden(true)
                            Text(row.name)
                                .font(ShellFont.tileName)
                            Spacer(minLength: 8)
                            Text("\(row.count)")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityLabel(row.name)
                        .accessibilityValue("\(row.count) \(SourceVocabulary.waitingToSync)")
                    }
                    .accessibilityIdentifier("shell.pane.status.waiting.\(row.route.id)")
                    .hoverEffect(.highlight)
                }
            }
        }
    }

    private var pillState: HomeStatusPillState {
        HomeStatusPillState.resolve(
            isPaired: self.appConfig.isPaired,
            status: self.connectionSyncModel.status,
            hasBacklog: self.waitingTotal > 0
        )
    }

    /// Offline says only where the material is — `on this device` — and never that it
    /// is safe: the app adds no protection of its own, so a safety claim would be
    /// asserting something we do not supply.
    private var leadStatusLine: String {
        switch self.pillState {
        case .syncing: SourceVocabulary.syncingToYourJournal
        case .caughtUp: SourceVocabulary.connectedLabel
        case .offline: SourceVocabulary.heldOnThisDevice
        case .notPaired: SourceVocabulary.dayLocalityNoJournal
        }
    }

    /// Orange is reserved for material actually moving. A held or unpaired state is
    /// not a warning and does not get the accent.
    private var leadStatusColor: Color {
        if case .syncing = self.pillState { return .solOrangeAdaptive }
        return .secondary
    }

    /// With nothing waiting the headline states the *sync* outcome when there is a
    /// journal, and the locality when there is not — never "all caught up" to an
    /// owner who has no journal to be caught up with.
    private var caughtUpHeadline: String {
        switch self.pillState {
        case .notPaired: SourceVocabulary.dayLocalityNoJournal
        case .offline: SourceVocabulary.heldOnThisDevice
        case .caughtUp, .syncing: SourceVocabulary.syncedHeadline
        }
    }

    private var waitingTotal: Int {
        self.waitingRows.reduce(0) { $0 + $1.count }
    }

    private struct WaitingRow {
        let route: SourceRoute
        let kind: SourceKind
        let name: String
        let count: Int
    }

    private var waitingRows: [WaitingRow] {
        let candidates = [
            WaitingRow(
                route: .audio,
                kind: .observer,
                name: "audio",
                count: self.mobileSegmentTransferHolder.pendingCount
                    + self.mobileSegmentTransferHolder.failedCount
            ),
            WaitingRow(
                route: .omi,
                kind: .omi,
                name: "omi pendant",
                count: self.omiUploaderHolder.pendingCount + self.omiUploaderHolder.failedCount
            ),
            WaitingRow(
                route: .watch,
                kind: .watch,
                name: "watch",
                count: self.watchUploaderHolder.pendingCount + self.watchUploaderHolder.failedCount
            ),
        ]
        return candidates.filter { $0.count > 0 }
    }

    @ViewBuilder
    var body: some View {
        if self.presentation.isPhoneModal {
            self.paneContent
                .accessibilityAddTraits(.isModal)
                .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            self.paneContent
        }
    }

    private var paneContent: some View {
        List {
            self.leadSection
            self.whatIsWaitingSection
            Section {
                let region = statusPaneRegion(self.connectionSyncModel.status)
                Text(region.value)
                    .font(.body.weight(.semibold))
                    .accessibilityIdentifier(region.id)
                    .accessibilityValue(region.value)

                if self.appConfig.isPaired {
                    LabeledContent(
                        "method",
                        value: self.shellStatusContext.via == .lan ? "local network" : "remote journal"
                    )
                    LabeledContent("journal", value: self.serverHost)
                    LabeledContent("uptime") {
                        Text(self.shellStatusContext.connectedSince, style: .timer)
                    }
                    LabeledContent(SourceVocabulary.transferRateLabel) {
                        Text(
                            self.transferRate > 0
                                ? SourceVocabulary.transferRateValue(bytesPerSecond: self.transferRate)
                                : SourceVocabulary.transferRateIdle
                        )
                    }
                    .accessibilityIdentifier("shell.pane.status.transferRate")
                    Text(SourceVocabulary.standingSyncFootnote(sustaining: self.locationManager.isSustainingBackground))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("shell.pane.status.syncFootnote")
                }
            } header: {
                Text(self.justCopiedSnapshot ? "copied" : SourceVocabulary.yourJournalSection)
                    .onLongPressGesture {
                        self.copySnapshot()
                    }
                    .accessibilityHint("long press to copy diagnostic snapshot")
            }

            Section("diagnostics") {
                Toggle(SourceVocabulary.problemReportsToggle, isOn: Binding(
                    get: { self.problemReportsManager.isEnabled },
                    set: { enabled in
                        UserSettings.problemReportsEnabled = enabled
                        self.problemReportsManager.setEnabled(enabled)
                    }
                ))
                .accessibilityIdentifier("shell.pane.status.problemReports.toggle")
                .accessibilityHint(SourceVocabulary.problemReportsToggleHint)

                NavigationLink(value: ShellDestination.problemReports) {
                    HStack {
                        Text(SourceVocabulary.problemReportsRow)
                        Spacer()
                        Text("\(self.problemReportsManager.reports.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("shell.pane.status.problemReports")
                .accessibilityHint(SourceVocabulary.problemReportsRowHint)
                .hoverEffect(.highlight)

                LabeledContent("tunnel reconnects", value: "\(self.tunnelManager.reconnectCount)")
                    .accessibilityLabel("tunnel reconnect count: \(self.tunnelManager.reconnectCount)")

                LabeledContent("network") {
                    Text(networkStatusText(self.tunnelManager.currentPathStatus))
                }
                .accessibilityLabel("network: \(networkStatusText(self.tunnelManager.currentPathStatus))")

                LabeledContent(SourceVocabulary.journalTunnel) {
                    Text(self.tunnelManager.state.isConnected ? "running" : "n/a")
                        .foregroundStyle(self.tunnelManager.state.isConnected ? .primary : .secondary)
                }
                .accessibilityLabel("\(SourceVocabulary.journalTunnel): \(self.tunnelManager.state.isConnected ? "running" : "not available")")

                Button {
                    Task {
                        await self.runProbe()
                    }
                } label: {
                    HStack {
                        Text(SourceVocabulary.checkConnection)
                        Spacer()
                        if self.isProbing {
                            ProgressView()
                                .controlSize(.small)
                        } else if let result = self.probeDisplay {
                            Text(result)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(self.probeDisplayColor)
                        }
                    }
                }
                .disabled(self.isProbing || !self.tunnelManager.state.isConnected)
                .accessibilityLabel(SourceVocabulary.checkConnection)
                .accessibilityHint(self.isProbing ? "probing in progress" : "tap to test connection health")
                .hoverEffect(.highlight)

                NavigationLink(value: ShellDestination.diagnostics) {
                    Text("event log")
                }
                .accessibilityIdentifier("shell.pane.status.diagnostics")
                .hoverEffect(.highlight)
            }
        }
        .navigationTitle(self.headingString)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if self.presentation.isPhoneModal {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        self.dismiss()
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Text(self.headingString)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.pane.status.heading")
                    .accessibilityFocused(self.$headingFocused)
            }
        }
        .accessibilityIdentifier("shell.pane.status")
        .onAppear { self.headingFocused = true }
        .onDisappear { self.snapshotCopyTask?.cancel() }
        .task { await self.refreshTransferRate() }
    }

    private func refreshTransferRate() async {
        while !Task.isCancelled {
            self.transferRate = recentBytesTotal(
                mobileSegment: self.mobileSegmentTransferHolder,
                omi: self.omiUploaderHolder,
                watch: self.watchUploaderHolder,
                share: self.shareTransferHolder
            )
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func runProbe() async {
        self.isProbing = true
        let result = await self.tunnelManager.probeConnection()
        self.isProbing = false
        guard let (alive, latency) = result else { return }
        let milliseconds = Int(latency.components.seconds) * 1000
            + Int(latency.components.attoseconds / 1_000_000_000_000_000)
        self.probeAlive = alive
        self.probeMilliseconds = milliseconds
        self.probeCheckedAt = Date()
        if UserSettings.haptics {
            UINotificationFeedbackGenerator().notificationOccurred(alive ? .success : .warning)
        }
    }

    private func copySnapshot() {
        let text = self.diagnosticLog.snapshot(
            tunnel: self.tunnelManager
        )
        UIPasteboard.general.string = text
        if UserSettings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        self.snapshotCopyTask?.cancel()
        withAnimation(.easeInOut) {
            self.justCopiedSnapshot = true
        }
        self.snapshotCopyTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                withAnimation(.easeInOut) {
                    self.justCopiedSnapshot = false
                }
            }
        }
    }
}
