// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

nonisolated enum StatusPaneWaitingSource: Equatable, Sendable {
    case audio
    case location
    case screencast
    case watch

    var route: SourceRoute {
        switch self {
        case .audio: .audio
        case .location: .location
        case .screencast: .screencast
        case .watch: .watch
        }
    }

    var kind: SourceKind {
        switch self {
        case .audio: .observer
        case .location: .location
        case .screencast: .screencast
        case .watch: .watch
        }
    }

    var name: String {
        switch self {
        case .audio: "audio"
        case .location: "location"
        case .screencast: SourceVocabulary.screencastDisplayName
        case .watch: "watch"
        }
    }
}

nonisolated struct StatusPaneWaitingRow: Equatable, Sendable {
    let source: StatusPaneWaitingSource
    let count: Int

    var route: SourceRoute { self.source.route }
    var kind: SourceKind { self.source.kind }
    var name: String { self.source.name }
}

nonisolated struct StatusPaneWaitingPresentation: Equatable, Sendable {
    let total: Int
    let rows: [StatusPaneWaitingRow]

    static func build(
        mobileAggregateCount: Int,
        audioCount: Int,
        locationCount: Int,
        screencastCount: Int,
        watchCount: Int
    ) -> Self {
        let candidates = [
            StatusPaneWaitingRow(source: .audio, count: audioCount),
            StatusPaneWaitingRow(source: .location, count: locationCount),
            StatusPaneWaitingRow(source: .screencast, count: screencastCount),
            StatusPaneWaitingRow(source: .watch, count: watchCount),
        ]
        return Self(
            total: mobileAggregateCount + watchCount,
            rows: candidates.filter { $0.count > 0 }
        )
    }
}

nonisolated enum StatusPaneStallTryAgain: Equatable, Sendable {
    case hidden
    case trying
    case ready

    nonisolated static func resolve(_ state: TunnelState) -> StatusPaneStallTryAgain {
        switch state {
        case .connecting, .connected:
            .trying
        case .waitingForHome, .disconnected:
            .ready
        case .error(let error):
            error.isRetryable ? .ready : .hidden
        }
    }

    func perform(_ action: () -> Void) {
        if case .ready = self { action() }
    }
}

nonisolated enum StatusPaneStallJournalRow: Equatable, Sendable {
    case reason
    case tryAgain(StatusPaneStallTryAgain)
    case pairAgain
    case addresses

    var accessibilityIdentifier: String {
        switch self {
        case .reason: "shell.pane.status.stall.reason"
        case .tryAgain: "shell.pane.status.stall.tryAgain"
        case .pairAgain: "shell.pane.status.stall.pairAgain"
        case .addresses: "shell.pane.status.addressesTried"
        }
    }
}

nonisolated enum StatusPaneStallJournal {
    static func rows(
        tryAgain: StatusPaneStallTryAgain,
        hasDisplayableLastHeard: Bool,
        hasTriedAddresses: Bool
    ) -> [StatusPaneStallJournalRow] {
        var rows: [StatusPaneStallJournalRow] = []
        if hasDisplayableLastHeard { rows.append(.reason) }
        if case .hidden = tryAgain {} else { rows.append(.tryAgain(tryAgain)) }
        rows.append(.pairAgain)
        if hasTriedAddresses { rows.append(.addresses) }
        return rows
    }
}

nonisolated struct StatusPaneLead: Equatable, Sendable {
    enum Lead: Equatable, Sendable {
        case count(count: Int, caption: String, statusLine: String)
        case headline(String)
    }

    enum Region: Equatable, Sendable {
        case status(title: String, identifier: String, accessibilityValue: String)
        case stalled
        case confirmMark(title: String, identifier: String)

        var accessibilityIdentifier: String {
            switch self {
            case .status(_, let identifier, _):
                identifier
            case .stalled:
                "shell.pane.status.degraded"
            case .confirmMark(_, let identifier):
                identifier
            }
        }
    }

    let lead: Lead
    let subline: String?
    let region: Region
    let showsStandingSyncFootnote: Bool
    /// The interruption notice beside a lead that is about something else (held, offline,
    /// sending, no journal). When the notice is itself the lead, this is false.
    var showsAudioInterruptionNotice = false

    var buttonTitle: String? {
        switch self.region {
        case .confirmMark(let title, _): title
        default: nil
        }
    }

    var headline: String {
        switch self.lead {
        case .headline(let text): text
        case .count(_, _, let statusLine): statusLine
        }
    }

    static func resolve(
        pillState: HomeStatusPillState,
        waitingTotal: Int,
        showsConnectionDetails: Bool,
        hasAudioInterruption: Bool = false
    ) -> StatusPaneLead {
        var resolved = Self.resolveLead(
            pillState: pillState,
            waitingTotal: waitingTotal,
            showsConnectionDetails: showsConnectionDetails
        )
        resolved.showsAudioInterruptionNotice = hasAudioInterruption && pillState != .audioInterrupted
        return resolved
    }

    private static func resolveLead(
        pillState: HomeStatusPillState,
        waitingTotal: Int,
        showsConnectionDetails: Bool
    ) -> StatusPaneLead {
        if pillState == .audioInterrupted {
            // The journal is reachable and nothing is waiting, so the connection row stays
            // `connected`; the lead says what did not arrive.
            return StatusPaneLead(
                lead: .headline(SourceVocabulary.audioInterruptedHeadline),
                subline: SourceVocabulary.audioInterruptedLine,
                region: .status(
                    title: SourceVocabulary.connectedLabel,
                    identifier: "shell.pane.status.connected",
                    accessibilityValue: SourceVocabulary.connectedLabel
                ),
                showsStandingSyncFootnote: showsConnectionDetails
            )
        }
        if pillState == .awaitingMarkConfirmation {
            let lead: Lead = waitingTotal > 0
                ? .count(
                    count: waitingTotal,
                    caption: SourceVocabulary.waitingToSync,
                    statusLine: SourceVocabulary.awaitingMarkConfirmationLine
                )
                : .headline(SourceVocabulary.awaitingMarkConfirmationLine)
            return StatusPaneLead(
                lead: lead,
                subline: SourceVocabulary.awaitingMarkConfirmationSubline,
                region: .confirmMark(
                    title: SourceVocabulary.confirmTheMarkAction,
                    identifier: "shell.pane.status.awaitingMarkConfirmation"
                ),
                showsStandingSyncFootnote: false
            )
        }

        let showsStandingSyncFootnote = showsConnectionDetails && pillState != .stalled
        let subline: String? = nil
        let region: Region
        if pillState == .stalled {
            region = .stalled
        } else {
            let identifier = (pillState == .caughtUp || pillState == .syncing)
                ? "shell.pane.status.connected"
                : "shell.pane.status.degraded"
            region = .status(
                title: pillState.label,
                identifier: identifier,
                accessibilityValue: pillState.label
            )
        }

        let lead: Lead
        if waitingTotal > 0 {
            let statusLine: String = switch pillState {
            case .syncing: SourceVocabulary.syncingToYourJournal
            case .caughtUp, .audioInterrupted: SourceVocabulary.connectedLabel
            case .connecting: SourceVocabulary.statusConnectingLabel
            case .offline: SourceVocabulary.heldOnThisDevice
            case .notPaired: SourceVocabulary.dayLocalityNoJournal
            case .stalled: SourceVocabulary.stallCantReachYourJournal
            case .awaitingMarkConfirmation: SourceVocabulary.awaitingMarkConfirmationLine
            }
            lead = .count(
                count: waitingTotal,
                caption: SourceVocabulary.waitingToSync,
                statusLine: statusLine
            )
        } else {
            let headline: String = switch pillState {
            case .notPaired: SourceVocabulary.dayLocalityNoJournal
            case .offline: SourceVocabulary.heldOnThisDevice
            case .connecting: SourceVocabulary.statusConnectingLabel
            case .caughtUp, .syncing: SourceVocabulary.syncedHeadline
            case .audioInterrupted: SourceVocabulary.audioInterruptedHeadline
            case .stalled: SourceVocabulary.stallCantReachYourJournal
            case .awaitingMarkConfirmation: SourceVocabulary.awaitingMarkConfirmationLine
            }
            lead = .headline(headline)
        }

        return StatusPaneLead(
            lead: lead,
            subline: subline,
            region: region,
            showsStandingSyncFootnote: showsStandingSyncFootnote
        )
    }
}

struct StatusPane: View {
    let presentation: ShellPanePresentation

    @Environment(AppConfig.self) private var appConfig
    @Environment(ShellStatusContext.self) private var shellStatusContext
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionStallMonitor.self) private var connectionStallMonitor
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(DiagnosticLog.self) private var diagnosticLog
    @Environment(ProblemReportsManager.self) private var problemReportsManager
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(ShareTransferHolder.self) private var shareTransferHolder
    @Environment(LocationManager.self) private var locationManager
    @Environment(PairFlowRouter.self) private var pairFlowRouter
    @Environment(JournalSendRelease.self) private var journalSendRelease
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

    /// The address the connection actually won through, else the first paired address.
    private var serverHost: String {
        self.tunnelManager.connectedDirectAddress ?? self.appConfig.host
    }

    /// Shown while not connected: the direct addresses the last dial tried, and how each went.
    private var triedAddresses: TriedAddresses? {
        guard self.appConfig.isPaired, let tried = self.tunnelManager.lastFailedDial else { return nil }
        switch self.tunnelManager.state {
        case .error, .waitingForHome:
            return tried
        case .connected, .connecting, .disconnected:
            return nil
        }
    }

    private var showsConnectionDetails: Bool {
        self.appConfig.isPaired && self.tunnelManager.state.isConnected
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

    private var leadModel: StatusPaneLead {
        StatusPaneLead.resolve(
            pillState: self.pillState,
            waitingTotal: self.waitingTotal,
            showsConnectionDetails: self.showsConnectionDetails,
            hasAudioInterruption: self.mobileSegmentTransferHolder.hasAudioInterruption
        )
    }

    private func confirmMarkTapped() {
        let decision = AwaitingMarkConfirmationPrompt.decide(
            retrySettled: self.appConfig.retrySettleIfNeeded(),
            awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation
        )
        if decision.kickConfirmedSend {
            self.journalSendRelease.kickConfirmedSend()
        }
        guard decision.present else { return }
        if self.presentation.isPhoneModal {
            self.dismiss()
            Task { @MainActor in
                self.pairFlowRouter.present(.confirmHeldJournal)
            }
        } else {
            self.pairFlowRouter.present(.confirmHeldJournal)
        }
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
                switch self.leadModel.lead {
                case .count(let count, let caption, let statusLine):
                    Text("\(count)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(caption)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        HomeStatusDot(state: self.pillState)
                        Text(statusLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(self.leadStatusColor)
                    }
                    .padding(.top, 8)
                case .headline(let headline):
                    HStack(spacing: 8) {
                        HomeStatusDot(state: self.pillState)
                        Text(headline)
                            .font(ShellFont.display(26, relativeTo: .title))
                            .foregroundStyle(.primary)
                    }
                }
                if let subline = self.leadModel.subline {
                    Text(subline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("shell.pane.status.lead")

            if self.leadModel.showsAudioInterruptionNotice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SourceVocabulary.audioInterruptedHeadline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(SourceVocabulary.audioInterruptedLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("shell.pane.status.audioInterrupted")
            }
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
            hasBacklog: self.waitingTotal > 0,
            isStalled: self.connectionStallMonitor.isStalled,
            awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation,
            hasAudioInterruption: self.mobileSegmentTransferHolder.hasAudioInterruption
        )
    }

    /// Orange is reserved for material actually moving. A held or unpaired state is
    /// not a warning and does not get the accent.
    private var leadStatusColor: Color {
        if case .syncing = self.pillState { return .solOrangeAdaptive }
        return .secondary
    }

    private var waitingTotal: Int {
        self.waitingPresentation.total
    }

    private var waitingRows: [StatusPaneWaitingRow] {
        self.waitingPresentation.rows
    }

    private var waitingPresentation: StatusPaneWaitingPresentation {
        let audio = self.mobileSegmentTransferHolder.summary(for: .audio)
        let location = self.mobileSegmentTransferHolder.summary(for: .location)
        let screencast = self.mobileSegmentTransferHolder.summary(for: .screencast)
        return StatusPaneWaitingPresentation.build(
            mobileAggregateCount: self.mobileSegmentTransferHolder.pendingCount
                + self.mobileSegmentTransferHolder.failedCount,
            audioCount: audio.pendingCount + audio.failedCount,
            locationCount: location.pendingCount + location.failedCount,
            screencastCount: screencast.pendingCount + screencast.failedCount,
            watchCount: self.watchUploaderHolder.pendingCount + self.watchUploaderHolder.failedCount
        )
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

    @ViewBuilder
    private func renderTriedAddresses(_ tried: TriedAddresses) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("addresses tried")
            ForEach(Array(tried.ownerLines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shell.pane.status.addressesTried")
    }

    @ViewBuilder
    private func renderStalledTryAgainButton(_ mode: StatusPaneStallTryAgain) -> some View {
        Button {
            mode.perform {
                Task {
                    await self.tunnelManager.retryNow()
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .trying ? SourceVocabulary.stallTryingLabel : SourceVocabulary.stallTryAgainLabel)
                    .font(.body)
                Text(SourceVocabulary.stallTriesEveryAddress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(mode != .ready)
        // A list button takes the accent tint, which painted this row and its sub-line link
        // blue beside a pair-again row in the pane ink. Same ink for both remedies.
        .tint(.primary)
        .accessibilityIdentifier(StatusPaneStallJournalRow.tryAgain(mode).accessibilityIdentifier)
    }

    @ViewBuilder
    private var renderStalledPairAgainLink: some View {
        NavigationLink(value: ShellDestination.pairFlow) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SourceVocabulary.stallPairAgainLabel)
                    .font(.body)
                Text(SourceVocabulary.stallPairAgainDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(StatusPaneStallJournalRow.pairAgain.accessibilityIdentifier)
    }

    @ViewBuilder
    private func renderStalledRow(_ row: StatusPaneStallJournalRow, carriesDegraded: Bool) -> some View {
        if carriesDegraded {
            VStack(alignment: .leading, spacing: 4) {
                Text("")
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(StatusPaneLead.Region.stalled.accessibilityIdentifier)
                switch row {
                case .reason:
                    if let heard = self.connectionStallMonitor.displayableLastHeardAt {
                        Text(SourceVocabulary.stallLastReached(date: heard, now: Date()))
                            .accessibilityIdentifier(row.accessibilityIdentifier)
                    }
                case .tryAgain(let mode):
                    self.renderStalledTryAgainButton(mode)
                case .pairAgain:
                    self.renderStalledPairAgainLink
                case .addresses:
                    if let tried = self.triedAddresses {
                        self.renderTriedAddresses(tried)
                    }
                }
            }
        } else {
            switch row {
            case .reason:
                if let heard = self.connectionStallMonitor.displayableLastHeardAt {
                    Text(SourceVocabulary.stallLastReached(date: heard, now: Date()))
                        .accessibilityIdentifier(row.accessibilityIdentifier)
                }
            case .tryAgain(let mode):
                self.renderStalledTryAgainButton(mode)
            case .pairAgain:
                self.renderStalledPairAgainLink
            case .addresses:
                if let tried = self.triedAddresses {
                    self.renderTriedAddresses(tried)
                }
            }
        }
    }

    private var paneContent: some View {
        List {
            self.leadSection
            self.whatIsWaitingSection
            Section {
                if self.pillState == .stalled {
                    let stalledRows = StatusPaneStallJournal.rows(
                        tryAgain: StatusPaneStallTryAgain.resolve(self.tunnelManager.state),
                        hasDisplayableLastHeard: self.connectionStallMonitor.displayableLastHeardAt != nil,
                        hasTriedAddresses: self.triedAddresses != nil
                    )
                    ForEach(Array(stalledRows.enumerated()), id: \.offset) { index, row in
                        self.renderStalledRow(row, carriesDegraded: index == 0)
                    }
                }

                if self.pillState != .stalled {
                    switch self.leadModel.region {
                    case .confirmMark(let title, let identifier):
                        Button(action: self.confirmMarkTapped) {
                            Text(title)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(identifier)
                    case .status(let title, let identifier, let accessibilityValue):
                        Text(title)
                            .font(.body.weight(.semibold))
                            .accessibilityIdentifier(identifier)
                            .accessibilityValue(accessibilityValue)
                    case .stalled:
                        EmptyView()
                    }
                }

                if self.pillState != .stalled {
                    if self.showsConnectionDetails {
                        LabeledContent(
                        "method",
                            value: self.shellStatusContext.via == .lan ? "local network" : "through the relay"
                        )
                        LabeledContent("your journal's address", value: self.serverHost)
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
                        if self.leadModel.showsStandingSyncFootnote {
                            Text(SourceVocabulary.standingSyncFootnote(sustaining: self.locationManager.isSustainingBackground))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("shell.pane.status.syncFootnote")
                        }
                    } else if let tried = self.triedAddresses {
                        self.renderTriedAddresses(tried)
                    }
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

                if self.tunnelManager.state.isConnected {
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
                    .accessibilityIdentifier("shell.pane.status.checkConnection")
                    .hoverEffect(.highlight)
                }

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
#if DEBUG
        .overlay(alignment: .topLeading) {
            UITestStateProbe(identifier: "shell.pane.status.leadState.\(self.pillState.uiTestStateName)")
        }
#endif
        .onAppear { self.headingFocused = true }
        .onDisappear { self.snapshotCopyTask?.cancel() }
        .task { await self.refreshTransferRate() }
    }

    private func refreshTransferRate() async {
        while !Task.isCancelled {
            self.transferRate = recentBytesTotal(
                mobileSegment: self.mobileSegmentTransferHolder,
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
