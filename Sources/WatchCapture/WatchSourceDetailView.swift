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
    @WatchPipelineInputReader private var watchPipelineInputs
    @Environment(WatchLink.self) private var watchLink
    @Environment(WatchSourceFacts.self) private var watchSourceFacts
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    @State private var setupDisclosureLatch = WatchSetupDisclosureLatch(
        isExpanded: false,
        lastHandledForegroundReturnGeneration: 0
    )
    @State private var steadyDetailsExpanded = false
    @State private var foregroundReturnGeneration = 0
    @State private var hasObservedNonActiveScenePhase = false
    @State private var celebrationRenderedThisVisit = false

    var pipelineInput: WatchPipelineInput {
        self.watchPipelineAssembly.input
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.content
                SourceHomeTileControl(sourceID: "watch")
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
        .onChange(of: self.scenePhase) { _, newPhase in
            self.handleScenePhaseChange(newPhase)
        }
        .onChange(of: self.setupDisclosureInputs) { _, _ in
            self.refreshSetupDisclosureLatch()
        }
    }
}

private extension WatchSourceDetailView {
    @ViewBuilder
    var content: some View {
        switch self.watchContentMode {
        case .setup(let card):
            SourceDetailBlock(title: card.header) {
                self.setupCardBlock(card)
            }
        case .celebrate:
            self.celebrationBanner
            self.steadyContent
        case .steady:
            self.steadyContent
        case .notice(let message):
            SourceDetailBlock(title: SourceVocabulary.watchSetupHeader) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        self.shareDiagnosticsLink(summary: self.summary)
    }

    @ViewBuilder
    var steadyContent: some View {
        SourceDetailBlock(title: SourceVocabulary.watchStateBlockTitle) {
            self.stateBlock
        }

        SourceDetailBlock(title: SourceVocabulary.watchDiagnosticsBlockTitle) {
            self.diagnosticsBlock
        }
    }

    var stateBlock: some View {
        let verdict = self.watchSteadyVerdict
        let lane = self.watchPipelineAssembly.lane
        let fault = watchSourceFault(lane)
        return VStack(alignment: .leading, spacing: 12) {
            SourceDetailVerdictLine(state: phoneWatchSourcePresentation(lane: lane).state)
            SourceDetailReasonLine(message: phoneWatchSourcePresentation(lane: lane).attention?.message)
            SourceFaultActionControl(
                action: fault.map(sourceFaultAction) ?? .none,
                title: SourceVocabulary.watchSetupInstallButton,
                hint: SourceVocabulary.watchSetupInstallButtonHint,
                perform: {}
            )
            self.verdictBlock(verdict)
            self.steadyDetailsDisclosure(verdict)
            if self.watchPipelineAssembly.waiting.watch.count > 0 {
                Button {
                    self.watchLink.retryOutstandingTransfers()
                } label: {
                    Label(SourceVocabulary.watchRetryTransfers, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!self.watchLink.isReachable || self.watchLink.activationState != .activated)
                .accessibilityIdentifier("watch.retryTransfers")
                .accessibilityHint(SourceVocabulary.watchRetryTransfersHint)
            }
        }
    }

    func verdictBlock(_ verdict: WatchSteadyVerdict) -> some View {
        let usesAttentionTint = watchSteadyVerdictUsesAttentionTint(verdict)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: verdict.state.symbol)
                .foregroundStyle(usesAttentionTint ? Color.solOrange : Color.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(verdict.headline)
                    .font(.headline)
                    .foregroundStyle(usesAttentionTint ? Color.orangeInk : Color.primary)
                Text(verdict.sentence)
                    .font(.subheadline)
                    .foregroundStyle(usesAttentionTint ? Color.orangeInk : Color.secondary)
                if let nextStep = verdict.nextStep {
                    Text(nextStep)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                if let presenceLine = verdict.presenceLine {
                    Text(presenceLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                if let todayLine = verdict.todayLine {
                    Text(todayLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(verdict.accessibilityLabel)
        .accessibilityIdentifier(watchSteadyVerdictAccessibilityIdentifier(verdict))
    }

    func steadyDetailsDisclosure(_ verdict: WatchSteadyVerdict) -> some View {
        DisclosureGroup(isExpanded: self.$steadyDetailsExpanded) {
            self.watchBlock
        } label: {
            Text(verdict.detailsSummary)
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel(verdict.detailsSummary)
    }

    var watchBlock: some View {
        let summary = self.summary
        let groups = WatchSourceDetailPresentation.pipelineGroups(summary.pipelineRows)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.rows) { row in
                        LabeledContent(row.label) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(row.value)
                                if let detail = row.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
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
        }
        .font(.subheadline)
    }

    var celebrationBanner: some View {
        Text(SourceVocabulary.watchSetupCelebration)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.orangeInk)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.solGold.opacity(0.22), in: ConcentricRectangle())
            .onAppear {
                self.celebrationRenderedThisVisit = true
                self.watchSourceFacts.noteFirstSegmentCelebrationShown()
            }
    }

    func setupCardBlock(_ card: WatchSetupCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(card.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !card.steps.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(card.steps.enumerated()), id: \.element.id) { index, step in
                        self.setupStepRow(step, index: index, total: card.steps.count)
                    }
                }
            }
        }
    }

    func setupStepRow(_ step: WatchSetupStep, index: Int, total: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: self.setupStepSymbol(step.state))
                .foregroundStyle(self.setupStepColor(step.state))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))

                if let subline = step.subline {
                    Text(subline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if step.id == .install {
                    self.installStepControls(step)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WatchSourceDetailPresentation.setupStepAccessibilityLabel(
            step: step,
            index: index,
            total: total
        ))
    }

    @ViewBuilder
    func installStepControls(_ step: WatchSetupStep) -> some View {
        if let buttonTitle = step.buttonTitle {
            Button {
                self.watchSourceFacts.noteInstallTapped()
                self.openURL(URL(string: "itms-watchs://")!) { accepted in
                    if !accepted {
                        watchSourceLog.info("watch install deep link not accepted")
                    }
                }
            } label: {
                Label(buttonTitle, systemImage: "applewatch")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("watch.installAffordance")
            .accessibilityHint(SourceVocabulary.watchSetupInstallButtonHint)
        }

        if let disclosure = step.disclosure {
            DisclosureGroup(isExpanded: self.setupDisclosureBinding) {
                Text(disclosure.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } label: {
                Text(disclosure.summary)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    func shareDiagnosticsLink(summary: WatchPipelineSummary) -> some View {
        ShareLink(
            item: WatchDiagnosticsExport(summary: summary),
            preview: SharePreview(SourceVocabulary.watchDiagnosticsExportFileName)
        ) {
            Label(SourceVocabulary.watchShareDiagnosticsLabel, systemImage: "square.and.arrow.up")
        }
        .frame(minHeight: 44)
        .accessibilityHint(SourceVocabulary.watchShareDiagnosticsHint)
    }

    var watchPipelineAssembly: WatchPipelineAssembly {
        self.watchPipelineInputs.assembly(now: self.now)
    }

    var watchFactsSnapshot: WatchSourceFacts.Snapshot {
        self.watchSourceFacts.snapshot
    }

    var watchSteadyVerdict: WatchSteadyVerdict {
        self.watchPipelineAssembly.steadyVerdict
    }

    var summary: WatchPipelineSummary {
        WatchPipelineReducer.reduce(self.pipelineInput)
    }

    var watchContentMode: WatchDetailContentMode {
        let assembly = self.watchPipelineAssembly
        let facts = self.watchFactsSnapshot
        return WatchSourceDetailPresentation.contentMode(
            lane: assembly.lane,
            installed: assembly.input.isWatchAppInstalled,
            checkedIn: facts.watchAppCheckedIn,
            firstSegment: facts.segmentFileReceived,
            celebrationShown: facts.firstSegmentCelebrationShown && !self.celebrationRenderedThisVisit
        )
    }

    var setupDisclosureBinding: Binding<Bool> {
        Binding {
            self.setupDisclosureLatch.isExpanded
        } set: { isExpanded in
            self.setupDisclosureLatch = WatchSetupDisclosureLatch(
                isExpanded: isExpanded,
                lastHandledForegroundReturnGeneration: self.setupDisclosureLatch.lastHandledForegroundReturnGeneration
            )
        }
    }

    var setupDisclosureInputs: WatchSetupDisclosureInputs {
        let assembly = self.watchPipelineAssembly
        let facts = self.watchFactsSnapshot
        return WatchSetupDisclosureInputs(
            installTapped: facts.installTapped,
            installed: assembly.input.isWatchAppInstalled,
            firstSegment: facts.segmentFileReceived,
            foregroundReturnGeneration: self.foregroundReturnGeneration
        )
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

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            guard self.hasObservedNonActiveScenePhase else {
                return
            }
            self.foregroundReturnGeneration += 1
            self.refreshSetupDisclosureLatch()
        case .inactive, .background:
            self.hasObservedNonActiveScenePhase = true
        @unknown default:
            self.hasObservedNonActiveScenePhase = true
        }
    }

    func refreshSetupDisclosureLatch() {
        let inputs = self.setupDisclosureInputs
        self.setupDisclosureLatch = WatchSourceDetailPresentation.disclosureLatch(
            current: self.setupDisclosureLatch,
            installTapped: inputs.installTapped,
            installed: inputs.installed,
            firstSegment: inputs.firstSegment,
            foregroundReturnGeneration: inputs.foregroundReturnGeneration
        )
    }

    func setupStepSymbol(_ state: WatchSetupStepState) -> String {
        switch state {
        case .pending:
            "circle"
        case .active:
            "circle.dotted"
        case .done:
            "checkmark.circle.fill"
        }
    }

    func setupStepColor(_ state: WatchSetupStepState) -> Color {
        switch state {
        case .pending:
            .secondary
        case .active:
            .solOrange
        case .done:
            .solGold
        }
    }
}

nonisolated func watchSteadyVerdictUsesAttentionTint(_ verdict: WatchSteadyVerdict) -> Bool {
    verdict.state == .needsAttention
}

nonisolated func watchSteadyVerdictAccessibilityIdentifier(_ verdict: WatchSteadyVerdict) -> String {
    switch verdict.kind {
    case .stuck:
        "watch.pipelineStuckNotice"
    case .stoppedItself:
        "watch.stoppedItselfNotice"
    case .observing, .receiving, .watchWaiting, .phoneSyncing, .caughtUp, .quiet:
        "watch.steadyVerdict"
    }
}

private struct WatchSetupDisclosureInputs: Equatable {
    let installTapped: Bool
    let installed: Bool
    let firstSegment: Bool
    let foregroundReturnGeneration: Int
}
#endif
