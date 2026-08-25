// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import XCTest

nonisolated final class WatchSourceDetailPresentationTests: XCTestCase {
    private func makeSummary(text: String) -> WatchPipelineSummary {
        WatchPipelineSummary(
            pipelineRows: [],
            syncSummary: WatchSourceSyncSummary(received: 0, waiting: 0, handedToJournal: 0, lastSyncAt: nil),
            diagnosticsRows: [],
            diagnosticsExportText: text,
            stuck: .none
        )
    }

    func testContentModeRoutesWatchStates() throws {
        XCTAssertEqual(
            Self.contentMode(lane: .unsupported),
            .steady
        )
        XCTAssertEqual(
            Self.contentMode(lane: .checking),
            .notice(SourceVocabulary.watchCheckingLine)
        )
        XCTAssertEqual(
            Self.contentMode(lane: .activationFailed),
            .notice(SourceVocabulary.watchActivationFailedSubtext)
        )

        let noWatch = try XCTUnwrap(Self.setupCard(from: Self.contentMode(lane: .noWatchPaired)))
        XCTAssertEqual(noWatch.header, SourceVocabulary.watchSetupHeader)
        XCTAssertEqual(noWatch.line, SourceVocabulary.watchSetupNoWatchBody)
        XCTAssertEqual(noWatch.steps, [])

        let ready = try XCTUnwrap(Self.setupCard(from: Self.contentMode(lane: .readyToSetUp(.installApp))))
        XCTAssertEqual(ready.line, SourceVocabulary.watchSetupValueLine)
        XCTAssertEqual(ready.steps.map(\.state), [.active, .pending, .pending])

        let unopened = try XCTUnwrap(Self.setupCard(from: Self.contentMode(
            lane: .installedNeverOpened,
            installed: true
        )))
        XCTAssertEqual(unopened.steps.map(\.state), [.done, .active, .pending])

        let checkedInAfterUninstall = try XCTUnwrap(Self.setupCard(from: Self.contentMode(
            lane: .installedActive(.idle(.unknown)),
            checkedIn: true
        )))
        XCTAssertEqual(checkedInAfterUninstall.steps.map(\.state), [.active, .done, .pending])

        XCTAssertEqual(
            Self.contentMode(lane: .installedActive(.receiving), firstSegment: true, celebrationShown: false),
            .celebrate
        )
        XCTAssertEqual(
            Self.contentMode(lane: .installedActive(.receiving), firstSegment: true, celebrationShown: true),
            .steady
        )
    }

    func testStepStatesClampFirstSegmentWithoutPromotingInstallFromCheckIn() {
        let incoherent = WatchSourceDetailPresentation.stepStates(
            lane: .installedActive(.idle(.unknown)),
            installed: false,
            checkedIn: false,
            firstSegment: true
        )
        XCTAssertEqual(incoherent.map(\.state), [.done, .done, .done])

        let checkedInAfterUninstall = WatchSourceDetailPresentation.stepStates(
            lane: .installedActive(.idle(.unknown)),
            installed: false,
            checkedIn: true,
            firstSegment: false
        )
        XCTAssertEqual(checkedInAfterUninstall.map(\.state), [.active, .done, .pending])
    }

    func testSetupStepSublinesRemainAcrossGeneratedStates() throws {
        let pending = try XCTUnwrap(Self.setupCard(from: Self.contentMode(lane: .readyToSetUp(.installApp))))
        let active = try XCTUnwrap(Self.setupCard(from: Self.contentMode(lane: .installedNeverOpened, installed: true)))
        let done = try XCTUnwrap(Self.setupCard(from: Self.contentMode(
            lane: .installedActive(.idle(.unknown)),
            installed: false,
            checkedIn: true
        )))
        let allSteps = pending.steps + active.steps + done.steps

        XCTAssertTrue(allSteps.filter { $0.id == .install }.allSatisfy {
            $0.subline == SourceVocabulary.watchSetupInstallSubline
        })
        XCTAssertTrue(allSteps.filter { $0.id == .open }.allSatisfy {
            $0.subline == SourceVocabulary.watchSetupOpenSubline
        })
        XCTAssertTrue(allSteps.filter { $0.id == .firstMoment }.allSatisfy { $0.subline == nil })
    }

    func testDisclosureLatchFollowsForegroundReturnStateMachine() {
        let collapsed = WatchSetupDisclosureLatch(isExpanded: false, lastHandledForegroundReturnGeneration: 0)
        XCTAssertEqual(
            WatchSourceDetailPresentation.disclosureLatch(
                current: collapsed,
                installTapped: false,
                installed: false,
                firstSegment: false,
                foregroundReturnGeneration: 0
            ),
            collapsed
        )
        XCTAssertEqual(
            WatchSourceDetailPresentation.disclosureLatch(
                current: collapsed,
                installTapped: true,
                installed: false,
                firstSegment: false,
                foregroundReturnGeneration: 0
            ),
            collapsed
        )
        XCTAssertEqual(
            WatchSourceDetailPresentation.disclosureLatch(
                current: collapsed,
                installTapped: true,
                installed: false,
                firstSegment: false,
                foregroundReturnGeneration: 1
            ),
            WatchSetupDisclosureLatch(isExpanded: true, lastHandledForegroundReturnGeneration: 1)
        )
        XCTAssertEqual(
            WatchSourceDetailPresentation.disclosureLatch(
                current: WatchSetupDisclosureLatch(isExpanded: false, lastHandledForegroundReturnGeneration: 1),
                installTapped: true,
                installed: false,
                firstSegment: false,
                foregroundReturnGeneration: 1
            ),
            WatchSetupDisclosureLatch(isExpanded: false, lastHandledForegroundReturnGeneration: 1)
        )
        XCTAssertEqual(
            WatchSourceDetailPresentation.disclosureLatch(
                current: WatchSetupDisclosureLatch(isExpanded: true, lastHandledForegroundReturnGeneration: 1),
                installTapped: true,
                installed: true,
                firstSegment: false,
                foregroundReturnGeneration: 2
            ),
            WatchSetupDisclosureLatch(isExpanded: false, lastHandledForegroundReturnGeneration: 2)
        )
        XCTAssertEqual(
            WatchSourceDetailPresentation.disclosureLatch(
                current: WatchSetupDisclosureLatch(isExpanded: true, lastHandledForegroundReturnGeneration: 2),
                installTapped: true,
                installed: false,
                firstSegment: true,
                foregroundReturnGeneration: 3
            ),
            WatchSetupDisclosureLatch(isExpanded: false, lastHandledForegroundReturnGeneration: 3)
        )
    }

    func testSetupStepAccessibilityLabelIncludesPositionTitleAndState() throws {
        let card = try XCTUnwrap(Self.setupCard(from: Self.contentMode(lane: .readyToSetUp(.installApp))))
        XCTAssertEqual(
            WatchSourceDetailPresentation.setupStepAccessibilityLabel(
                step: card.steps[0],
                index: 0,
                total: card.steps.count
            ),
            "step 1 of 3, \(SourceVocabulary.watchSetupInstallTitle), \(SourceVocabulary.watchSetupStepActive)"
        )
    }

    func testSteadyVerdictIdentifierAndTintSeparateStoppedItselfFromStuck() {
        let stuck = Self.verdict(kind: .stuck(.relay), state: .needsAttention)
        let stopped = Self.verdict(kind: .stoppedItself(.audioStoppedItself), state: .needsAttention)
        let quiet = Self.verdict(kind: .quiet, state: .off)

        XCTAssertTrue(watchSteadyVerdictUsesAttentionTint(stuck))
        XCTAssertTrue(watchSteadyVerdictUsesAttentionTint(stopped))
        XCTAssertFalse(watchSteadyVerdictUsesAttentionTint(quiet))
        XCTAssertEqual(watchSteadyVerdictAccessibilityIdentifier(stuck), "watch.pipelineStuckNotice")
        XCTAssertEqual(watchSteadyVerdictAccessibilityIdentifier(stopped), "watch.stoppedItselfNotice")
        XCTAssertEqual(watchSteadyVerdictAccessibilityIdentifier(quiet), "watch.steadyVerdict")
    }

    func testInstallButtonKeepsAccessibilityIdentifierAndHint() throws {
        let viewText = try String(
            contentsOf: Self.worktreeRoot().appendingPathComponent("Sources/WatchCapture/WatchSourceDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewText.contains(".accessibilityIdentifier(self.setupActionAccessibilityIdentifier(step.id))"))
        XCTAssertTrue(viewText.contains("\"watch.installAffordance\""))
        XCTAssertTrue(viewText.contains(".accessibilityHint(SourceVocabulary.watchSetupInstallButtonHint)"))
    }

    func testSetupActionsFollowInstallAndCheckInStates() throws {
        let installSteps = WatchSourceDetailPresentation.stepStates(
            lane: .readyToSetUp(.installApp),
            installed: false,
            checkedIn: false,
            firstSegment: false
        )
        XCTAssertEqual(try Self.setupStep(.install, in: installSteps).buttonTitle, SourceVocabulary.watchSetupInstallButton)
        XCTAssertNil(try Self.setupStep(.open, in: installSteps).buttonTitle)

        let openSteps = WatchSourceDetailPresentation.stepStates(
            lane: .installedNeverOpened,
            installed: true,
            checkedIn: false,
            firstSegment: false
        )
        XCTAssertNil(try Self.setupStep(.install, in: openSteps).buttonTitle)
        XCTAssertEqual(try Self.setupStep(.open, in: openSteps).buttonTitle, SourceVocabulary.watchSetupInstallButton)

        let checkedInSteps = WatchSourceDetailPresentation.stepStates(
            lane: .installedActive(.idle(.unknown)),
            installed: true,
            checkedIn: true,
            firstSegment: false
        )
        XCTAssertNil(try Self.setupStep(.install, in: checkedInSteps).buttonTitle)
        XCTAssertNil(try Self.setupStep(.open, in: checkedInSteps).buttonTitle)
    }

    func testInstallAndOpenAffordancesHaveDistinctIdentifiersAndOneVerifiedRoute() throws {
        let viewText = try String(
            contentsOf: Self.worktreeRoot().appendingPathComponent("Sources/WatchCapture/WatchSourceDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewText.contains("\"watch.installAffordance\""))
        XCTAssertTrue(viewText.contains("\"watch.openAffordance\""))
        XCTAssertEqual(viewText.components(separatedBy: "itms-watchs://").count, 2)
        XCTAssertTrue(viewText.contains("if step.id == .install {\n                    self.watchSourceFacts.noteInstallTapped()"))
        XCTAssertTrue(viewText.contains("self.openWatchApp()"))
    }

    func testSteadySourceOrderUsesVerdictDisclosureAndDeletesStuckNoticeBlock() throws {
        let viewText = try String(
            contentsOf: Self.worktreeRoot().appendingPathComponent("Sources/WatchCapture/WatchSourceDetailView.swift"),
            encoding: .utf8
        )
        let presentationText = try String(
            contentsOf: Self.worktreeRoot().appendingPathComponent("Sources/WatchCapture/WatchSourceDetailPresentation.swift"),
            encoding: .utf8
        )

        let stateBlockRange = try XCTUnwrap(viewText.range(
            of: "SourceDetailBlock(title: SourceVocabulary.watchStateBlockTitle)"
        ))
        let diagnosticsBlockRange = try XCTUnwrap(viewText.range(
            of: "SourceDetailBlock(title: SourceVocabulary.watchDiagnosticsBlockTitle)"
        ))
        let verdictBlockRange = try XCTUnwrap(viewText.range(of: "self.verdictBlock(verdict)"))
        let detailsDisclosureRange = try XCTUnwrap(viewText.range(of: "self.steadyDetailsDisclosure(verdict)"))
        XCTAssertLessThan(stateBlockRange.lowerBound, diagnosticsBlockRange.lowerBound)
        XCTAssertLessThan(verdictBlockRange.lowerBound, detailsDisclosureRange.lowerBound)
        XCTAssertFalse(viewText.contains("SourceDetailBlock(title: \"watch\")"))
        XCTAssertTrue(viewText.contains("@State private var steadyDetailsExpanded = false"))
        XCTAssertTrue(viewText.contains("DisclosureGroup(isExpanded: self.$steadyDetailsExpanded)"))
        XCTAssertTrue(viewText.contains("Text(verdict.detailsSummary)"))
        XCTAssertTrue(viewText.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(viewText.contains(".accessibilityLabel(verdict.accessibilityLabel)"))
        XCTAssertTrue(viewText.contains(".accessibilityLabel(verdict.detailsSummary)"))
        XCTAssertTrue(viewText.contains("WatchSourceDetailPresentation.pipelineGroups(summary.pipelineRows)"))
        XCTAssertFalse(viewText.contains("stuckNoticeBlock(summary.stuck)"))
        XCTAssertFalse(viewText.contains("func stuckNoticeBlock"))
        XCTAssertFalse(presentationText.contains("WatchStuckNotice"))
        XCTAssertFalse(presentationText.contains("stuckNotice(for:"))
    }

    func testPipelineGroupsSplitWatchReportedAndPhoneKnownRows() {
        let rows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: "3", detail: "as of 1m ago"),
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSending, value: "1"),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "5"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "2"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "3"),
        ]

        let groups = WatchSourceDetailPresentation.pipelineGroups(rows)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].label, SourceVocabulary.watchPipelineReportedGroupLabel)
        XCTAssertEqual(groups[0].rows.map(\.label), [
            SourceVocabulary.watchPipelineSaved,
            SourceVocabulary.watchPipelineSending,
        ])
        XCTAssertEqual(groups[0].rows[0].detail, "as of 1m ago")
        XCTAssertEqual(groups[1].label, SourceVocabulary.watchPipelineKnownGroupLabel)
        XCTAssertEqual(groups[1].rows.map(\.label), [
            SourceVocabulary.watchReceivedLabel,
            SourceVocabulary.watchNotYetInJournalLabel,
            SourceVocabulary.watchHandedToJournalLabel,
        ])
    }

    func testDiagnosticsExportValueReflectsSummaryTextAndFilename() {
        let summary = WatchPipelineSummary(
            pipelineRows: [],
            syncSummary: WatchSourceSyncSummary(received: 0, waiting: 0, handedToJournal: 0, lastSyncAt: nil),
            diagnosticsRows: [],
            diagnosticsExportText: SourceVocabulary.watchPipelineOrphanStuckReason,
            stuck: .orphan
        )
        let export = WatchDiagnosticsExport(summary: summary)

        XCTAssertEqual(export.text, SourceVocabulary.watchPipelineOrphanStuckReason)
        XCTAssertEqual(export.filename, SourceVocabulary.watchDiagnosticsExportFileName)
    }

    func testDiagnosticsExportVendsFileWithPinnedBasenameAndContents() async throws {
        let text = "diagnostics-\(UUID().uuidString)\nsecond line"
        let export = WatchDiagnosticsExport(summary: makeSummary(text: text))

        try await export.withExportedFile(contentType: .plainText) { url in
            XCTAssertEqual(url.lastPathComponent, SourceVocabulary.watchDiagnosticsExportFileName)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(contents, text)
        }
    }

    func testBackToBackTransfersUseDistinctSubdirsAndKeepEachGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let textA = "generation-A-\(UUID().uuidString)"
        let textB = "generation-B-\(UUID().uuidString)"

        let urlA = try WatchDiagnosticsExport.writeTransferFile(text: textA, into: root)
        let urlB = try WatchDiagnosticsExport.writeTransferFile(text: textB, into: root)

        XCTAssertNotEqual(urlA.deletingLastPathComponent(), urlB.deletingLastPathComponent())
        XCTAssertEqual(urlA.lastPathComponent, SourceVocabulary.watchDiagnosticsExportFileName)
        XCTAssertEqual(urlB.lastPathComponent, SourceVocabulary.watchDiagnosticsExportFileName)
        XCTAssertEqual(try String(contentsOf: urlA, encoding: .utf8), textA)
        XCTAssertEqual(try String(contentsOf: urlB, encoding: .utf8), textB)

        try? FileManager.default.removeItem(at: root)
    }

    func testRepeatedExportsKeepTempAreaBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let iterations = WatchDiagnosticsExport.maxRetainedExportDirectories + 12

        for index in 0..<iterations {
            _ = try WatchDiagnosticsExport.writeTransferFile(text: "gen-\(index)", into: root)
        }

        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertLessThanOrEqual(entries.count, WatchDiagnosticsExport.maxRetainedExportDirectories)

        try? FileManager.default.removeItem(at: root)
    }
}

private extension WatchSourceDetailPresentationTests {
    static func contentMode(
        lane: PhoneWatchSourceLane,
        installed: Bool = false,
        checkedIn: Bool = false,
        firstSegment: Bool = false,
        celebrationShown: Bool = false
    ) -> WatchDetailContentMode {
        WatchSourceDetailPresentation.contentMode(
            lane: lane,
            installed: installed,
            checkedIn: checkedIn,
            firstSegment: firstSegment,
            celebrationShown: celebrationShown
        )
    }

    static func setupCard(from mode: WatchDetailContentMode) -> WatchSetupCard? {
        guard case .setup(let card) = mode else {
            return nil
        }
        return card
    }

    static func setupStep(_ id: WatchSetupStepID, in steps: [WatchSetupStep]) throws -> WatchSetupStep {
        try XCTUnwrap(steps.first { $0.id == id })
    }

    static func verdict(
        kind: WatchSteadyVerdictKind,
        state: SourceState
    ) -> WatchSteadyVerdict {
        WatchSteadyVerdict(
            kind: kind,
            state: state,
            headline: "headline",
            sentence: "sentence",
            nextStep: nil,
            presenceLine: nil,
            todayLine: nil,
            detailsSummary: "summary",
            accessibilityLabel: "headline sentence"
        )
    }

    static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
