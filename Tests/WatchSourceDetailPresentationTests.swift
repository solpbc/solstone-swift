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

    func testInstallAffordanceIsTextOnlyAndOnlyForReadyToSetUp() throws {
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(lane: .unsupported))
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(lane: .noWatchPaired))
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(lane: .installedNeverOpened))
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(lane: .installedActive(.idle)))

        let affordance = try XCTUnwrap(WatchSourceDetailPresentation.installAffordance(lane: .readyToSetUp(.installApp)))

        XCTAssertEqual(affordance.title, SourceVocabulary.watchInstallTitle)
        XCTAssertEqual(affordance.instruction, SourceVocabulary.watchInstallInstruction)
        XCTAssertFalse(Mirror(reflecting: affordance).children.contains { $0.label == "action" })
    }

    func testStuckNoticeMapsCopyWhenStuck() throws {
        XCTAssertNil(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.none))

        let relay = try XCTUnwrap(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.relay))
        let handoff = try XCTUnwrap(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.handoff))
        let orphan = try XCTUnwrap(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.orphan))

        XCTAssertEqual(relay.title, SourceVocabulary.watchStuckNoticeTitle)
        XCTAssertEqual(relay.reason, SourceVocabulary.watchPipelineRelayStuckReason)
        XCTAssertEqual(relay.nextStep, SourceVocabulary.watchPipelineRelayStuckNextStep)
        XCTAssertEqual(handoff.title, SourceVocabulary.watchStuckNoticeTitle)
        XCTAssertEqual(handoff.reason, SourceVocabulary.watchPipelineHandoffStuckReason)
        XCTAssertEqual(handoff.nextStep, SourceVocabulary.watchPipelineHandoffStuckNextStep)
        XCTAssertEqual(orphan.title, SourceVocabulary.watchStuckNoticeTitle)
        XCTAssertEqual(orphan.reason, SourceVocabulary.watchPipelineOrphanStuckReason)
        XCTAssertEqual(orphan.nextStep, SourceVocabulary.watchPipelineOrphanStuckNextStep)
    }

    func testPipelineGroupsSplitWatchReportedAndPhoneKnownRows() {
        let rows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: "3"),
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
