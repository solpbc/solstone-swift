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
