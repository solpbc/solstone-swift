// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity
import XCTest

nonisolated final class WatchSourceDetailPresentationTests: XCTestCase {
    func testSyncSummaryCountsReceivedAsWaitingUntilUploadCompletes() {
        let staged = WatchSourceDetailPresentation.syncSummary(
            received: 1,
            pending: 1,
            failed: 0,
            lastUploadAt: nil
        )

        XCTAssertEqual(staged.received, 1)
        XCTAssertEqual(staged.waiting, 1)
        XCTAssertEqual(staged.handedToJournal, 0)
        XCTAssertNil(staged.lastSyncAt)

        let uploadCompletedAt = Date(timeIntervalSince1970: 1_000)
        let uploaded = WatchSourceDetailPresentation.syncSummary(
            received: 1,
            pending: 0,
            failed: 0,
            lastUploadAt: uploadCompletedAt
        )

        XCTAssertEqual(uploaded.received, 1)
        XCTAssertEqual(uploaded.waiting, 0)
        XCTAssertEqual(uploaded.handedToJournal, 1)
        XCTAssertEqual(uploaded.lastSyncAt, uploadCompletedAt)
    }

    func testAllFailedUploadsRemainWaitingWithoutWatchFaultState() {
        let now = Date(timeIntervalSince1970: 2_000)
        let summary = WatchSourceDetailPresentation.syncSummary(
            received: 2,
            pending: 0,
            failed: 2,
            lastUploadAt: nil
        )
        let state = phoneWatchSourceState(install: .appInstalled, observing: true, enabled: true)
        let rows = WatchSourceDetailPresentation.syncRows(summary: summary, now: now)

        XCTAssertEqual(summary.received, 2)
        XCTAssertEqual(summary.waiting, 2)
        XCTAssertEqual(summary.handedToJournal, 0)
        XCTAssertEqual(state.0, .active)
        XCTAssertNil(state.1)
        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchWaitingLabel }?.value, "2")
        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchHandedToJournalLabel }?.value, "0")
        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchLastSyncLabel }?.value, SourceVocabulary.watchLastSyncNever)
        XCTAssertFalse(rows.contains { $0.label.localizedCaseInsensitiveContains("failed") })
        XCTAssertFalse(rows.contains { $0.value.localizedCaseInsensitiveContains("not working") })
    }

    func testDiagnosticsRowsKeepUploadErrorsNeutral() {
        let now = Date(timeIntervalSince1970: 2_000)
        let rows = WatchSourceDetailPresentation.diagnosticsRows(
            activationState: .activated,
            isPaired: true,
            isWatchAppInstalled: true,
            lastReceivedAt: now.addingTimeInterval(-30),
            lastStagingError: nil,
            lastUploadAt: nil,
            lastUploadError: "connection failed",
            now: now
        )

        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchLastUploadErrorLabel }?.value, SourceVocabulary.watchDetailPresent)
        for row in rows {
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("failed"))
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("not working"))
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("sync failed"))
            XCTAssertFalse(row.value.localizedCaseInsensitiveContains("failed"))
            XCTAssertFalse(row.value.localizedCaseInsensitiveContains("not working"))
            XCTAssertFalse(row.value.localizedCaseInsensitiveContains("sync failed"))
        }
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

    func testDiagnosticsExportIncludesSyncAndDiagnosticsRows() {
        let syncRows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "1"),
        ]
        let diagnosticsRows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchInstalledLabel, value: SourceVocabulary.watchBooleanYes),
        ]

        let export = WatchSourceDetailPresentation.diagnosticsExportText(
            syncRows: syncRows,
            diagnosticsRows: diagnosticsRows
        )

        XCTAssertTrue(export.contains(SourceVocabulary.watchDiagnosticsExportTitle))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchReceivedLabel): 1"))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchInstalledLabel): \(SourceVocabulary.watchBooleanYes)"))
    }
}
