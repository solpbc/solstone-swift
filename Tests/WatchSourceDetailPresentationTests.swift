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
        let state = phoneWatchSourceState(install: .appInstalled, recordingStatus: .observing)
        let rows = WatchSourceDetailPresentation.pipelineRows(
            context: nil,
            summary: summary,
            now: now,
            ttl: WatchRecordingStatus.defaultTTL
        )

        XCTAssertEqual(summary.received, 2)
        XCTAssertEqual(summary.waiting, 2)
        XCTAssertEqual(summary.handedToJournal, 0)
        XCTAssertEqual(state.0, .active)
        XCTAssertNil(state.1)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchNotYetInJournalLabel }?.value, "2")
        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchHandedToJournalLabel }?.value, "0")
        XCTAssertFalse(rows.contains { $0.label == SourceVocabulary.watchLastSyncLabel })
        XCTAssertFalse(rows.contains { $0.label == "waiting" })
        XCTAssertFalse(rows.contains { $0.label.localizedCaseInsensitiveContains("failed") })
        XCTAssertFalse(rows.contains { $0.value.localizedCaseInsensitiveContains("not working") })
    }

    func testPipelineRowsShowFreshContextAsLiveCounts() {
        let now = Date(timeIntervalSince1970: 2_000)
        let summary = WatchSourceSyncSummary(received: 5, waiting: 2, handedToJournal: 3, lastSyncAt: now)
        let rows = WatchSourceDetailPresentation.pipelineRows(
            context: Self.context(queuedCount: 3, transferringCount: 1, asOf: now.addingTimeInterval(-10)),
            summary: summary,
            now: now,
            ttl: WatchRecordingStatus.defaultTTL
        )

        XCTAssertEqual(rows, [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: "3"),
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSending, value: "1"),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "5"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "2"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "3"),
        ])
    }

    func testPipelineRowsShowStaleContextAgeOnlyForWatchRows() {
        let now = Date(timeIntervalSince1970: 2_000)
        let secondsAgo: TimeInterval = 120
        let summary = WatchSourceSyncSummary(received: 5, waiting: 2, handedToJournal: 3, lastSyncAt: now)
        let relative = WatchSourceDetailPresentation.relativeText(secondsAgo: secondsAgo)
        let rows = WatchSourceDetailPresentation.pipelineRows(
            context: Self.context(queuedCount: 3, transferringCount: 1, asOf: now.addingTimeInterval(-secondsAgo)),
            summary: summary,
            now: now,
            ttl: WatchRecordingStatus.defaultTTL
        )

        XCTAssertEqual(rows, [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: "3 · \(relative)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSending, value: "1 · \(relative)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "5"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "2"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "3"),
        ])
    }

    func testPipelineRowsUseUnknownOnlyForWatchRowsWhenContextIsMissing() {
        let now = Date(timeIntervalSince1970: 2_000)
        let summary = WatchSourceSyncSummary(received: 5, waiting: 2, handedToJournal: 3, lastSyncAt: nil)
        let rows = WatchSourceDetailPresentation.pipelineRows(
            context: nil,
            summary: summary,
            now: now,
            ttl: WatchRecordingStatus.defaultTTL
        )

        XCTAssertEqual(rows, [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: SourceVocabulary.watchPipelineUnknown),
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSending, value: SourceVocabulary.watchPipelineUnknown),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "5"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "2"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "3"),
        ])
        XCTAssertNotEqual(rows[0].value, "0")
        XCTAssertNotEqual(rows[1].value, "0")
    }

    func testPipelineRowsClampNegativeContextCounts() {
        let now = Date(timeIntervalSince1970: 2_000)
        let summary = WatchSourceSyncSummary(received: 5, waiting: 2, handedToJournal: 3, lastSyncAt: nil)
        let rows = WatchSourceDetailPresentation.pipelineRows(
            context: Self.context(queuedCount: -3, transferringCount: -1, asOf: now),
            summary: summary,
            now: now,
            ttl: WatchRecordingStatus.defaultTTL
        )

        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchPipelineSaved }?.value, "0")
        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchPipelineSending }?.value, "0")
    }

    func testDiagnosticsRowsShowUploadErrorDetail() {
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

        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchLastUploadErrorLabel }?.value, "connection failed")
        XCTAssertEqual(rows.first { $0.label == SourceVocabulary.watchStatusLabel }?.value, SourceVocabulary.watchDetailNone)
        for row in rows {
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("failed"))
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("not working"))
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("sync failed"))
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
        let primaryRows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "1"),
        ]
        let diagnosticsRows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchInstalledLabel, value: SourceVocabulary.watchBooleanYes),
        ]

        let export = WatchSourceDetailPresentation.diagnosticsExportText(
            primaryRows: primaryRows,
            diagnosticsRows: diagnosticsRows
        )

        XCTAssertTrue(export.contains(SourceVocabulary.watchDiagnosticsExportTitle))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchReceivedLabel): 1"))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchInstalledLabel): \(SourceVocabulary.watchBooleanYes)"))
    }

    func testDiagnosticsExportIncludesPipelineRowsWithoutPrimaryLastSyncRow() {
        let now = Date(timeIntervalSince1970: 2_000)
        let rows = WatchSourceDetailPresentation.pipelineRows(
            context: Self.context(queuedCount: 2, transferringCount: 1, asOf: now),
            summary: WatchSourceSyncSummary(received: 3, waiting: 1, handedToJournal: 2, lastSyncAt: now),
            now: now,
            ttl: WatchRecordingStatus.defaultTTL
        )

        let export = WatchSourceDetailPresentation.diagnosticsExportText(primaryRows: rows, diagnosticsRows: [])
        let lines = export.split(separator: "\n").map(String.init)

        XCTAssertTrue(export.contains("\(SourceVocabulary.watchPipelineSaved): 2"))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchPipelineSending): 1"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("\(SourceVocabulary.watchLastSyncLabel):") })
    }
}

private extension WatchSourceDetailPresentationTests {
    static func context(queuedCount: Int, transferringCount: Int, asOf: Date) -> WatchStatusContext {
        WatchStatusContext(
            phase: .idle,
            sessionID: nil,
            startedAt: nil,
            asOf: asOf,
            seq: 1,
            queuedCount: queuedCount,
            transferringCount: transferringCount
        )
    }
}
