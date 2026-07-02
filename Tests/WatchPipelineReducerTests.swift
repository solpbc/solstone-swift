// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity
import XCTest

nonisolated final class WatchPipelineReducerTests: XCTestCase {
    func testReduceHealthyFlowingBuildsRowsSummaryDiagnosticsAndExport() {
        let now = Self.now
        let input = Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 3, transferringCount: 1, asOf: now.addingTimeInterval(-10)),
            lifetimeReceived: 5,
            lifetimeHanded: 3,
            nonTerminalCount: 2,
            lastHandedAt: now,
            lastUploadAt: now.addingTimeInterval(-20),
            lastReceivedAt: now.addingTimeInterval(-30)
        )

        let summary = WatchPipelineReducer.reduce(input)

        XCTAssertEqual(summary.pipelineRows, [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: "3"),
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSending, value: "1"),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "5"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "2"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "3"),
        ])
        XCTAssertEqual(summary.syncSummary, WatchSourceSyncSummary(received: 5, waiting: 2, handedToJournal: 3, lastSyncAt: now))
        XCTAssertEqual(summary.stuck, WatchPipelineStuck.none)
        XCTAssertEqual(summary.diagnosticsRows.first { $0.label == SourceVocabulary.watchStatusLabel }?.value, "idle · \(Self.relativeText(secondsAgo: 10))")
        XCTAssertTrue(summary.diagnosticsExportText.contains("\(SourceVocabulary.watchPipelineSaved): 3"))
    }

    func testReduceWatchSuspendedStaleAgesOnlyWatchRows() {
        let now = Self.now
        let secondsAgo: TimeInterval = 120
        let relative = Self.relativeText(secondsAgo: secondsAgo)
        let summary = WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 3, transferringCount: 1, asOf: now.addingTimeInterval(-secondsAgo)),
            lifetimeReceived: 5,
            lifetimeHanded: 3,
            nonTerminalCount: 2,
            lastReceivedAt: now
        ))

        XCTAssertEqual(summary.pipelineRows, [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: "3 · \(relative)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSending, value: "1 · \(relative)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "5"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "2"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "3"),
        ])
        XCTAssertEqual(summary.stuck, WatchPipelineStuck.none)
    }

    func testReduceFirstRunPreservesUnknownForNeverReportedWatchClaim() {
        let summary = WatchPipelineReducer.reduce(Self.input(
            watchStatus: nil,
            lifetimeReceived: 5,
            lifetimeHanded: 3,
            nonTerminalCount: 2
        ))

        XCTAssertEqual(summary.pipelineRows, [
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: SourceVocabulary.watchPipelineUnknown),
            WatchSourceDetailRow(label: SourceVocabulary.watchPipelineSending, value: SourceVocabulary.watchPipelineUnknown),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "5"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "2"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "3"),
        ])
        XCTAssertNotEqual(summary.pipelineRows[0].value, "0")
        XCTAssertNotEqual(summary.pipelineRows[1].value, "0")
    }

    func testReduceShowsLedgerErrorInDiagnosticsAndExport() {
        let summary = WatchPipelineReducer.reduce(Self.input(lastLedgerError: "persist failed"))

        XCTAssertEqual(
            summary.diagnosticsRows.first { $0.label == SourceVocabulary.watchLastLedgerDetailLabel }?.value,
            "persist failed"
        )
        XCTAssertTrue(summary.diagnosticsExportText.contains("\(SourceVocabulary.watchLastLedgerDetailLabel): persist failed"))
    }

    func testReducerClampsNegativeCountsAndFutureWatchEpochs() {
        let now = Self.now
        let summary = WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: -3, transferringCount: -1, asOf: now.addingTimeInterval(60)),
            lifetimeReceived: -5,
            lifetimeHanded: -3,
            nonTerminalCount: -2
        ))

        XCTAssertEqual(summary.pipelineRows.first { $0.label == SourceVocabulary.watchPipelineSaved }?.value, "0")
        XCTAssertEqual(summary.pipelineRows.first { $0.label == SourceVocabulary.watchPipelineSending }?.value, "0")
        XCTAssertEqual(summary.syncSummary, WatchSourceSyncSummary(received: 0, waiting: 0, handedToJournal: 0, lastSyncAt: nil))
    }

    func testWatchClaimStalenessUsesNinetySecondBoundary() {
        let now = Self.now
        let atBoundary = WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, transferringCount: 1, asOf: now.addingTimeInterval(-90))
        ))
        let justPastBoundary = WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, transferringCount: 1, asOf: now.addingTimeInterval(-91))
        ))

        XCTAssertEqual(atBoundary.pipelineRows[0].value, "1")
        XCTAssertTrue(justPastBoundary.pipelineRows[0].value.hasPrefix("1 · "))
        XCTAssertEqual(justPastBoundary.pipelineRows[2].value, "0")
    }

    func testRelayStuckBoundariesAndExclusions() {
        let now = Self.now
        let relayBase = Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now.addingTimeInterval(-90)),
            lastReceivedAt: now.addingTimeInterval(-600)
        )

        XCTAssertEqual(WatchPipelineReducer.reduce(relayBase).stuck, .relay)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now.addingTimeInterval(-90)),
            lastReceivedAt: now.addingTimeInterval(-599)
        )).stuck, WatchPipelineStuck.none)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now.addingTimeInterval(-91)),
            lastReceivedAt: now.addingTimeInterval(-600)
        )).stuck, WatchPipelineStuck.none)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now),
            lastReceivedAt: nil
        )).stuck, WatchPipelineStuck.none)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now),
            lastReceivedAt: now.addingTimeInterval(-600),
            isPaired: false
        )).stuck, WatchPipelineStuck.none)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now),
            lastReceivedAt: now.addingTimeInterval(-600),
            isWatchAppInstalled: false
        )).stuck, WatchPipelineStuck.none)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now),
            lastReceivedAt: now.addingTimeInterval(-600),
            activationState: .inactive
        )).stuck, WatchPipelineStuck.none)
    }

    func testHandoffStuckBoundariesAndReachability() {
        let now = Self.now

        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-599),
            pendingCount: 1,
            isJournalReachable: true
        )).stuck, WatchPipelineStuck.none)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-600),
            pendingCount: 1,
            isJournalReachable: true
        )).stuck, .handoff)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-600),
            inFlightCount: 1,
            isJournalReachable: true
        )).stuck, .handoff)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-600),
            pendingCount: 1,
            isJournalReachable: false
        )).stuck, WatchPipelineStuck.none)
    }

    func testOrphanStuckBoundariesAndQueueExclusions() {
        let now = Self.now

        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-1_799)
        )).stuck, WatchPipelineStuck.none)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-1_800)
        )).stuck, .orphan)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-1_800),
            inFlightCount: 1,
            isJournalReachable: true
        )).stuck, .handoff)
        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-600)
        )).stuck, WatchPipelineStuck.none)
    }

    func testQuietPipelineAndOverlapPrecedence() {
        let now = Self.now

        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            lastHandedAt: nil,
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-60),
            pendingCount: 1,
            isJournalReachable: true
        )).stuck, WatchPipelineStuck.none)

        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now),
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-600),
            pendingCount: 1,
            lastReceivedAt: now.addingTimeInterval(-600),
            isJournalReachable: true
        )).stuck, .handoff)

        XCTAssertEqual(WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now),
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-1_800),
            lastReceivedAt: now.addingTimeInterval(-600)
        )).stuck, .orphan)
    }

    func testStuckReasonsAreDistinctAndExportIncludesReason() {
        XCTAssertNotEqual(WatchPipelineStuck.relay.reason, WatchPipelineStuck.handoff.reason)
        XCTAssertNotEqual(WatchPipelineStuck.handoff.reason, WatchPipelineStuck.orphan.reason)
        XCTAssertNotEqual(WatchPipelineStuck.relay.reason, WatchPipelineStuck.orphan.reason)

        let summary = WatchPipelineReducer.reduce(Self.input(
            oldestNonTerminalReceivedAt: Self.now.addingTimeInterval(-1_800)
        ))

        XCTAssertEqual(summary.stuck, .orphan)
        XCTAssertTrue(summary.diagnosticsExportText.contains(SourceVocabulary.watchPipelineOrphanStuckReason))
    }
}

private extension WatchPipelineReducerTests {
    static let now = Date(timeIntervalSince1970: 2_000)

    static func context(
        phase: WatchStatusContext.Phase = .idle,
        queuedCount: Int = 0,
        transferringCount: Int = 0,
        asOf: Date = Date(timeIntervalSince1970: 2_000)
    ) -> WatchStatusContext {
        WatchStatusContext(
            phase: phase,
            sessionID: nil,
            startedAt: nil,
            asOf: asOf,
            seq: 1,
            queuedCount: queuedCount,
            transferringCount: transferringCount
        )
    }

    static func input(
        now: Date = Date(timeIntervalSince1970: 2_000),
        watchStatus: WatchStatusContext? = nil,
        lifetimeReceived: Int = 0,
        lifetimeHanded: Int = 0,
        nonTerminalCount: Int = 0,
        lastHandedAt: Date? = nil,
        oldestNonTerminalReceivedAt: Date? = nil,
        lastLedgerError: String? = nil,
        pendingCount: Int = 0,
        failedCount: Int = 0,
        inFlightCount: Int = 0,
        lastUploadAt: Date? = nil,
        lastUploadError: String? = nil,
        lastReceivedAt: Date? = nil,
        lastStagingError: String? = nil,
        isPaired: Bool = true,
        isWatchAppInstalled: Bool = true,
        activationState: WCSessionActivationState = .activated,
        isJournalReachable: Bool = false
    ) -> WatchPipelineInput {
        WatchPipelineInput(
            now: now,
            watchStatus: watchStatus,
            lifetimeReceived: lifetimeReceived,
            lifetimeHanded: lifetimeHanded,
            nonTerminalCount: nonTerminalCount,
            lastHandedAt: lastHandedAt,
            oldestNonTerminalReceivedAt: oldestNonTerminalReceivedAt,
            lastLedgerError: lastLedgerError,
            pendingCount: pendingCount,
            failedCount: failedCount,
            inFlightCount: inFlightCount,
            lastUploadAt: lastUploadAt,
            lastUploadError: lastUploadError,
            lastReceivedAt: lastReceivedAt,
            lastStagingError: lastStagingError,
            isPaired: isPaired,
            isWatchAppInstalled: isWatchAppInstalled,
            activationState: activationState,
            isJournalReachable: isJournalReachable
        )
    }

    static func relativeText(secondsAgo: TimeInterval) -> String {
        if secondsAgo < 60 {
            return SourceVocabulary.watchRelativeJustNow
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(fromTimeInterval: -secondsAgo)
    }
}
