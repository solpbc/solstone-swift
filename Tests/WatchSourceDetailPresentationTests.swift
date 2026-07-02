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

    func testInstallAffordanceIsTextOnlyAndOnlyForPairedNoApp() throws {
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(install: .notSupported))
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(install: .noWatchPaired))
        XCTAssertNil(WatchSourceDetailPresentation.installAffordance(install: .appInstalled))

        let affordance = try XCTUnwrap(WatchSourceDetailPresentation.installAffordance(install: .pairedNoApp))

        XCTAssertEqual(affordance.title, SourceVocabulary.watchInstallTitle)
        XCTAssertEqual(affordance.instruction, SourceVocabulary.watchInstallInstruction)
        XCTAssertFalse(Mirror(reflecting: affordance).children.contains { $0.label == "action" })
    }

    func testStuckNoticeReturnsReasonOnlyWhenStuck() throws {
        XCTAssertNil(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.none))

        let relay = try XCTUnwrap(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.relay))
        let handoff = try XCTUnwrap(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.handoff))
        let orphan = try XCTUnwrap(WatchSourceDetailPresentation.stuckNotice(for: WatchPipelineStuck.orphan))

        XCTAssertEqual(relay.reason, SourceVocabulary.watchPipelineRelayStuckReason)
        XCTAssertEqual(handoff.reason, SourceVocabulary.watchPipelineHandoffStuckReason)
        XCTAssertEqual(orphan.reason, SourceVocabulary.watchPipelineOrphanStuckReason)
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
