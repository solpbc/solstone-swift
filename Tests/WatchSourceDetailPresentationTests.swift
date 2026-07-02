// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class WatchSourceDetailPresentationTests: XCTestCase {
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
}
