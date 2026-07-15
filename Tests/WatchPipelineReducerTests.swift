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
        XCTAssertTrue(summary.diagnosticsExportText.contains(SourceVocabulary.watchDiagnosticsStageRetentionAppleQueue))
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
            WatchSourceDetailRow(
                label: SourceVocabulary.watchPipelineSaved,
                value: "3",
                detail: SourceVocabulary.watchPipelineStaleAsOf(relative)
            ),
            WatchSourceDetailRow(
                label: SourceVocabulary.watchPipelineSending,
                value: "1",
                detail: SourceVocabulary.watchPipelineStaleAsOf(relative)
            ),
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

    func testDiagnosticsRowsAndExportIncludeWatchReachability() {
        let reachable = WatchPipelineReducer.reduce(Self.input(isReachable: true))
        XCTAssertEqual(
            reachable.diagnosticsRows.first { $0.label == SourceVocabulary.watchReachableLabel }?.value,
            SourceVocabulary.watchBooleanYes
        )
        XCTAssertTrue(reachable.diagnosticsExportText.contains("\(SourceVocabulary.watchReachableLabel): \(SourceVocabulary.watchBooleanYes)"))

        let notReachable = WatchPipelineReducer.reduce(Self.input(isReachable: false))
        XCTAssertEqual(
            notReachable.diagnosticsRows.first { $0.label == SourceVocabulary.watchReachableLabel }?.value,
            SourceVocabulary.watchBooleanNo
        )
        XCTAssertTrue(notReachable.diagnosticsExportText.contains("\(SourceVocabulary.watchReachableLabel): \(SourceVocabulary.watchBooleanNo)"))
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
        XCTAssertNil(atBoundary.pipelineRows[0].detail)
        XCTAssertEqual(justPastBoundary.pipelineRows[0].value, "1")
        XCTAssertEqual(
            justPastBoundary.pipelineRows[0].detail,
            SourceVocabulary.watchPipelineStaleAsOf(Self.relativeText(secondsAgo: 91))
        )
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

    func testDiagnosticsExportIncludesStaleWatchDetailAndStuckReason() {
        let now = Self.now
        let secondsAgo: TimeInterval = 120
        let relative = Self.relativeText(secondsAgo: secondsAgo)
        let summary = WatchPipelineReducer.reduce(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 3, asOf: now.addingTimeInterval(-secondsAgo)),
            oldestNonTerminalReceivedAt: now.addingTimeInterval(-1_800)
        ))

        XCTAssertTrue(summary.diagnosticsExportText.contains(SourceVocabulary.watchDiagnosticsStageWatchSnapshot))
        XCTAssertTrue(
            summary.diagnosticsExportText.contains(
                "\(SourceVocabulary.watchStatusLabel): idle · \(relative)"
            )
        )
        XCTAssertTrue(summary.diagnosticsExportText.contains(SourceVocabulary.watchPipelineOrphanStuckReason))
    }

    func testWatchReachabilityDoesNotAffectStuckDetection() {
        let now = Self.now
        let base = Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now.addingTimeInterval(-90)),
            lastReceivedAt: now.addingTimeInterval(-600),
            isReachable: false
        )
        let reachable = Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 1, asOf: now.addingTimeInterval(-90)),
            lastReceivedAt: now.addingTimeInterval(-600),
            isReachable: true
        )

        XCTAssertEqual(WatchPipelineReducer.reduce(base).stuck, .relay)
        XCTAssertEqual(WatchPipelineReducer.reduce(reachable).stuck, WatchPipelineReducer.reduce(base).stuck)
    }

    func testClassificationDenominatorsUseVisibleActiveDistinctNotOmittedObservationCount() {
        let visible = (0..<10).map { index in
            Self.observation(id: Self.uuid(index), relation: index == 0 ? .duplicate : .matched)
        }
        let orphan = Self.observation(id: Self.uuid(100), relation: .orphaned)
        let payload = Self.payload(
            activeBacklogCount: 15,
            observations: visible + [orphan],
            omittedObservationCount: 8
        )
        let input = Self.input(
            watchDiagnostics: .available(payload, rawEnvelopeByteCount: nil),
            phoneLedgerSnapshot: .available(Self.ledgerSnapshot(entries: [:]))
        )

        let report = WatchPipelineReducer.classifyRelayIdentities(input)
        let export = WatchPipelineReducer.reduce(input).diagnosticsExportText

        XCTAssertEqual(report.activeBacklogCount.value, 15)
        XCTAssertEqual(report.visibleActiveDistinctCount, 10)
        XCTAssertEqual(report.omittedActiveCount.value, 5)
        XCTAssertEqual(report.omittedObservationCount, 8)
        XCTAssertEqual(report.classifications.count, 10)
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchDiagnosticsActiveBacklogLabel): 15"))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchDiagnosticsVisibleActiveLabel): 10"))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchDiagnosticsOmittedActiveLabel): 5"))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchDiagnosticsOmittedObservationsLabel): 8"))
        XCTAssertEqual(
            export.components(separatedBy: SourceVocabulary.watchDiagnosticsVisibleActiveClassificationLabel).count - 1,
            10
        )
    }

    func testClassificationCoversPhoneOutcomesAndLedgerAbsentSourceAssessments() {
        let handedWithACKID = Self.uuid(200)
        let handedWithoutACKID = Self.uuid(201)
        let receivedID = Self.uuid(202)
        let droppedID = Self.uuid(203)
        let pendingID = Self.uuid(204)
        let copyBackedID = Self.uuid(205)
        let staleID = Self.uuid(206)
        let unresolvedID = Self.uuid(207)
        let missingBundleID = Self.uuid(208)
        let observations = [
            Self.observation(id: handedWithACKID),
            Self.observation(id: handedWithoutACKID),
            Self.observation(id: receivedID),
            Self.observation(id: droppedID),
            Self.observation(id: pendingID, audio: Self.original(.readableNonempty, bytes: 42), bundlePresent: false, bundleBytes: 0),
            Self.observation(id: copyBackedID, audio: Self.original(.missing, bytes: 0), location: Self.original(.zeroLength, bytes: 0), bundlePresent: true, bundleBytes: 128),
            Self.observation(id: staleID, relation: .appActiveNotObserved, audio: Self.original(.missing, bytes: 0), location: Self.original(.unreadable, bytes: nil), bundlePresent: false, bundleBytes: 0),
            Self.observation(id: unresolvedID, collectionResolution: .available(.snapshotChangedDuringCollection)),
            Self.observation(
                id: missingBundleID,
                relation: .appActiveNotObserved,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: false,
                bundleBytes: 0,
                relayBundleBytes: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            ),
        ]
        let ledgerSnapshot = Self.ledgerSnapshot(entries: [
            handedWithACKID: Self.ledgerEntry(id: handedWithACKID, state: .handed),
            handedWithoutACKID: Self.ledgerEntry(id: handedWithoutACKID, state: .handed),
            receivedID: Self.ledgerEntry(id: receivedID, state: .received),
            droppedID: Self.ledgerEntry(id: droppedID, state: .dropped),
        ])
        let input = Self.input(
            watchDiagnostics: .available(Self.payload(activeBacklogCount: observations.count, observations: observations), rawEnvelopeByteCount: nil),
            phoneLedgerSnapshot: .available(ledgerSnapshot),
            iphoneACKQueueSnapshot: Self.ackSnapshot(ids: [handedWithACKID])
        )

        let report = WatchPipelineReducer.classifyRelayIdentities(input)
        let byID = Dictionary(uniqueKeysWithValues: report.classifications.map { ($0.segmentID, $0) })

        XCTAssertEqual(byID[handedWithACKID]?.phoneOutcome, .alreadyHanded(ackQueued: true))
        XCTAssertEqual(byID[handedWithoutACKID]?.phoneOutcome, .alreadyHanded(ackQueued: false))
        XCTAssertEqual(byID[receivedID]?.phoneOutcome, .receivedStaged)
        XCTAssertEqual(byID[droppedID]?.phoneOutcome, .terminalDropped)
        XCTAssertEqual(byID[pendingID]?.phoneOutcome, .ledgerAbsent)
        XCTAssertEqual(byID[pendingID]?.sourceAssessment, .pending)
        XCTAssertEqual(byID[copyBackedID]?.sourceAssessment, .copyBacked)
        XCTAssertEqual(byID[staleID]?.sourceAssessment, .staleSourceEmpty)
        XCTAssertEqual(byID[missingBundleID]?.sourceAssessment, .staleSourceEmpty)
        XCTAssertEqual(byID[unresolvedID]?.sourceAssessment, .unresolved)

        let export = WatchPipelineReducer.reduce(input).diagnosticsExportText
        XCTAssertTrue(export.contains("phone already handed to journal / Watch retention-cleanup lag; ack queued yes"))
        XCTAssertTrue(export.contains("phone already handed to journal / Watch retention-cleanup lag; ack queued no"))
        XCTAssertTrue(export.contains("phone received/staged, journal handoff not proven"))
        XCTAssertTrue(export.contains("phone terminal-dropped / Watch retention-cleanup lag"))
        XCTAssertTrue(export.contains("source pending"))
        XCTAssertTrue(export.contains("source copy-backed"))
        XCTAssertTrue(export.contains("source stale-source-empty"))
        XCTAssertTrue(export.contains("source unresolved"))
        XCTAssertTrue(export.contains("ledger not present in retained phone ledger"))
    }

    func testLedgerAbsentSourceAssessmentHonorsAppleFileTransferMatch() {
        let matchedBundleAbsentID = Self.uuid(300)
        let matchedBundleZeroID = Self.uuid(301)
        let duplicateBundleAbsentID = Self.uuid(302)
        let appActiveEmptyID = Self.uuid(303)
        let matchedReadableOriginalID = Self.uuid(304)
        let appActiveReadableOriginalID = Self.uuid(305)
        let appActivePositiveBundleID = Self.uuid(306)
        let matchedSnapshotChangedID = Self.uuid(307)
        let matchedUnavailableBundleBytesID = Self.uuid(308)
        let appActiveUnavailableBundleBytesID = Self.uuid(309)
        let observations = [
            Self.observation(
                id: matchedBundleAbsentID,
                relation: .matched,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: false,
                bundleBytes: 0
            ),
            Self.observation(
                id: matchedBundleZeroID,
                relation: .matched,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: true,
                bundleBytes: 0
            ),
            Self.observation(
                id: duplicateBundleAbsentID,
                relation: .duplicate,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: false,
                bundleBytes: 0
            ),
            Self.observation(
                id: appActiveEmptyID,
                relation: .appActiveNotObserved,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: true,
                bundleBytes: 0
            ),
            Self.observation(
                id: matchedReadableOriginalID,
                relation: .matched,
                audio: Self.original(.readableNonempty, bytes: 42),
                bundlePresent: false,
                bundleBytes: 0
            ),
            Self.observation(
                id: appActiveReadableOriginalID,
                relation: .appActiveNotObserved,
                audio: Self.original(.readableNonempty, bytes: 42),
                bundlePresent: false,
                bundleBytes: 0
            ),
            Self.observation(
                id: appActivePositiveBundleID,
                relation: .appActiveNotObserved,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: true,
                bundleBytes: 128
            ),
            Self.observation(
                id: matchedSnapshotChangedID,
                relation: .matched,
                collectionResolution: .available(.snapshotChangedDuringCollection)
            ),
            Self.observation(
                id: matchedUnavailableBundleBytesID,
                relation: .matched,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: true,
                bundleBytes: 0,
                relayBundleBytes: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            ),
            Self.observation(
                id: appActiveUnavailableBundleBytesID,
                relation: .appActiveNotObserved,
                audio: Self.original(.missing, bytes: 0),
                location: Self.original(.zeroLength, bytes: 0),
                bundlePresent: true,
                bundleBytes: 0,
                relayBundleBytes: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
            ),
        ]
        let ledgerSnapshot = Self.ledgerSnapshot(entries: [:])
        let input = Self.input(
            watchDiagnostics: .available(Self.payload(activeBacklogCount: observations.count, observations: observations), rawEnvelopeByteCount: nil),
            phoneLedgerSnapshot: .available(ledgerSnapshot),
            iphoneACKQueueSnapshot: Self.ackSnapshot(ids: [])
        )

        let report = WatchPipelineReducer.classifyRelayIdentities(input)
        let byID = Dictionary(uniqueKeysWithValues: report.classifications.map { ($0.segmentID, $0) })

        XCTAssertEqual(byID[matchedBundleAbsentID]?.sourceAssessment, .copyBacked)
        XCTAssertEqual(byID[matchedBundleZeroID]?.sourceAssessment, .copyBacked)
        XCTAssertEqual(byID[duplicateBundleAbsentID]?.sourceAssessment, .copyBacked)
        XCTAssertEqual(byID[appActiveEmptyID]?.sourceAssessment, .staleSourceEmpty)
        XCTAssertEqual(byID[matchedReadableOriginalID]?.sourceAssessment, .pending)
        XCTAssertEqual(byID[appActiveReadableOriginalID]?.sourceAssessment, .pending)
        XCTAssertEqual(byID[appActivePositiveBundleID]?.sourceAssessment, .copyBacked)
        XCTAssertEqual(byID[matchedSnapshotChangedID]?.sourceAssessment, .unresolved)
        XCTAssertEqual(byID[matchedUnavailableBundleBytesID]?.sourceAssessment, .copyBacked)
        XCTAssertEqual(byID[appActiveUnavailableBundleBytesID]?.sourceAssessment, .unresolved)

        let export = WatchPipelineReducer.reduce(input).diagnosticsExportText
        XCTAssertTrue(export.contains("source copy-backed"))
        XCTAssertTrue(export.contains("apple relation matched"))
        XCTAssertTrue(export.contains("apple relation duplicate"))
        XCTAssertTrue(export.contains("relation matched"))
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
        isJournalReachable: Bool = false,
        isReachable: Bool = false,
        watchDiagnostics: WatchRelayDiagnosticsEnvelopeResult = .absent,
        phoneLedgerSnapshot: DiagnosticAvailability<WatchSegmentLedgerReadSnapshot> = .unavailable(reason: "not provided"),
        iphoneACKQueueSnapshot: WatchRelayACKQueueSnapshot = WatchRelayACKQueueSnapshot()
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
            isReachable: isReachable,
            isJournalReachable: isJournalReachable,
            watchDiagnostics: watchDiagnostics,
            phoneLedgerSnapshot: phoneLedgerSnapshot,
            iphoneACKQueueSnapshot: iphoneACKQueueSnapshot
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

    static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    static func payload(
        activeBacklogCount: Int,
        observations: [WatchRelayTransferObservation],
        omittedObservationCount: Int = 0
    ) -> WatchRelayDiagnosticsPayload {
        WatchRelayDiagnosticsPayload(
            watchAppMarketingVersion: .available("0.1.0"),
            watchAppBuild: .available("55"),
            watchOSVersion: .available("26.0"),
            activationState: "activated",
            isCompanionAppInstalled: .available(true),
            isReachable: true,
            iOSDeviceNeedsUnlockAfterRebootForReachability: .available(false),
            hasContentPending: false,
            watchBatteryLevel: .available(0.75),
            watchBatteryState: .available("unplugged"),
            watchLowPowerModeEnabled: .available(false),
            watchThermalState: .available("nominal"),
            manifestSummary: .available(WatchRelayManifestSummary(
                counts: .zero,
                activeBacklogCount: activeBacklogCount,
                retainedSourceBytes: .available(0),
                oldestActiveEnqueuedAt: .available(nil),
                oldestActiveEnqueueAgeSeconds: .available(nil)
            )),
            appleQueue: .available(WatchRelayAppleQueueSnapshot(
                asOf: Self.now,
                outstandingFileTransferCount: observations.count,
                outstandingUserInfoTransferCountWatchToPhone: 0,
                reconciliation: .zero,
                exactObservationCountBeforeCompaction: observations.count + omittedObservationCount
            )),
            lastFacts: .available(WatchRelayLastFactsSummary(
                lastEnqueue: nil,
                lastTransferCompletion: nil,
                lastStructuredFailure: nil,
                lastDurableACK: nil,
                lastQueueReconciliationObservation: nil,
                lastBackgroundWakeCompletion: nil,
                lastBackgroundWakeDeadline: nil
            )),
            observedFileTransfers: observations,
            omittedObservationCount: omittedObservationCount
        )
    }

    static func observation(
        id: UUID,
        relation: WatchRelayObservationRelation = .matched,
        audio: DiagnosticAvailability<WatchRelayOriginalFileFact> = .available(
            WatchRelayOriginalFileFact(state: .missing, byteCount: 0)
        ),
        location: DiagnosticAvailability<WatchRelayOriginalFileFact> = .available(
            WatchRelayOriginalFileFact(state: .missing, byteCount: 0)
        ),
        bundlePresent: Bool = true,
        bundleBytes: Int64 = 128,
        relayBundleBytes: DiagnosticAvailability<Int64>? = nil,
        collectionResolution: DiagnosticAvailability<WatchRelayObservationCollectionResolution> = .available(.stable)
    ) -> WatchRelayTransferObservation {
        WatchRelayTransferObservation(
            asOf: Self.now,
            segmentID: id,
            idState: .parseable,
            relation: relation,
            appManifestState: relation == .orphaned ? nil : WatchSegmentState.transferring.rawValue,
            appOwnedEnqueueAgeSeconds: .available(30),
            appOwnedSourceBytes: .available(bundleBytes),
            sourcePresent: .available(bundlePresent),
            isTransferring: .available(true),
            progress: .available(MockWatchConnectivitySession.defaultProgress()),
            originalAudioFile: audio,
            originalLocationFile: location,
            relayBundlePresent: .available(bundlePresent),
            relayBundleBytes: relayBundleBytes ?? .available(bundleBytes),
            collectionResolution: collectionResolution
        )
    }

    static func original(_ state: WatchRelayOriginalFileState, bytes: Int64?) -> DiagnosticAvailability<WatchRelayOriginalFileFact> {
        .available(WatchRelayOriginalFileFact(state: state, byteCount: bytes))
    }

    static func ledgerSnapshot(
        entries: [UUID: WatchSegmentLedgerEntrySnapshot]
    ) -> WatchSegmentLedgerReadSnapshot {
        var received = 0
        var handed = 0
        var dropped = 0
        var handedAndDropped = 0
        for entry in entries.values {
            switch entry.state {
            case .received:
                received += 1
            case .handed:
                handed += 1
            case .dropped:
                dropped += 1
            case .handedAndDropped:
                handedAndDropped += 1
            }
        }
        return WatchSegmentLedgerReadSnapshot(
            asOf: Self.now,
            entriesByID: entries,
            counts: WatchSegmentLedgerSnapshotCounts(
                retainedEntryCount: entries.count,
                receivedOnlyCount: received,
                handedCount: handed,
                droppedCount: dropped,
                handedAndDroppedCount: handedAndDropped
            )
        )
    }

    static func ledgerEntry(
        id: UUID,
        state: WatchSegmentLedgerEntryState
    ) -> WatchSegmentLedgerEntrySnapshot {
        let receivedAt = Self.now.addingTimeInterval(-30)
        let handedAt = state == .handed || state == .handedAndDropped ? Self.now.addingTimeInterval(-20) : nil
        let droppedAt = state == .dropped || state == .handedAndDropped ? Self.now.addingTimeInterval(-10) : nil
        return WatchSegmentLedgerEntrySnapshot(
            segmentID: id,
            state: state,
            receivedAt: state == .dropped ? nil : receivedAt,
            handedAt: handedAt,
            droppedAt: droppedAt,
            receivedAgeSeconds: state == .dropped ? nil : 30,
            handedAgeSeconds: handedAt == nil ? nil : 20,
            droppedAgeSeconds: droppedAt == nil ? nil : 10
        )
    }

    static func ackSnapshot(ids: [UUID]) -> WatchRelayACKQueueSnapshot {
        WatchRelayACKQueueSnapshot(userInfoTransfers: ids.map { id in
            WatchConnectivityUserInfoTransferSnapshot(
                asOf: Self.now,
                recognizedType: .watchSegmentACK,
                segmentID: id,
                idState: .parseable,
                isTransferring: true
            )
        })
    }
}
