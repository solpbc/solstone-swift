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

    func testPhoneWaitingUsesLedgerNonTerminalCountOnly() {
        let input = Self.input(
            nonTerminalCount: 2,
            pendingCount: 2,
            failedCount: 2,
            inFlightCount: 2
        )

        XCTAssertEqual(WatchPipelineReducer.phoneWaitingCount(input), 2)
        XCTAssertEqual(WatchPipelineReducer.reduce(input).syncSummary.waiting, 2)
        XCTAssertTrue(
            WatchPipelineReducer.reduce(input).diagnosticsExportText.contains(
                "\(SourceVocabulary.watchNotYetInJournalLabel): 2"
            )
        )
    }

    func testWaitingBreakdownSelectsLeadingPortionWithoutSumming() {
        let now = Self.now

        let freshWatchBeatsPhone = WatchPipelineReducer.waitingBreakdown(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 3, transferringCount: 0, asOf: now),
            nonTerminalCount: 2
        ))
        XCTAssertEqual(freshWatchBeatsPhone.leading, .watch(count: 3, freshness: .fresh(asOf: now)))

        let staleWatchFallsBackToPhone = WatchPipelineReducer.waitingBreakdown(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 3, transferringCount: 0, asOf: now.addingTimeInterval(-91)),
            nonTerminalCount: 2
        ))
        XCTAssertEqual(staleWatchFallsBackToPhone.leading, .phone(count: 2))

        let zeroEverywhere = WatchPipelineReducer.waitingBreakdown(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 0, transferringCount: 0, asOf: now),
            nonTerminalCount: 0
        ))
        XCTAssertNil(zeroEverywhere.leading)

        let overlapTie = WatchPipelineReducer.waitingBreakdown(Self.input(
            now: now,
            watchStatus: Self.context(queuedCount: 0, transferringCount: 1, asOf: now),
            nonTerminalCount: 1
        ))
        XCTAssertEqual(overlapTie.leading, .phone(count: 1))
        XCTAssertNotEqual(overlapTie.leading?.count, 2)
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

    func testSteadyVerdictStuckWinsAndCarriesReasonAndNextStep() {
        let input = Self.input(
            nonTerminalCount: 3,
            oldestNonTerminalReceivedAt: Self.now.addingTimeInterval(-1_800)
        )

        let verdict = Self.steadyVerdict(input)

        XCTAssertEqual(verdict.kind, .stuck(.orphan))
        XCTAssertEqual(verdict.state, .needsAttention)
        XCTAssertEqual(verdict.headline, SourceVocabulary.watchStuckNoticeTitle)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchPipelineOrphanStuckReason)
        XCTAssertEqual(verdict.nextStep, SourceVocabulary.watchPipelineOrphanStuckNextStep)
    }

    func testSteadyVerdictStoppedItselfOutranksStuckAndWaiting() {
        func status(
            terminalReason: WatchCaptureTerminalReason?,
            terminalDisposition: WatchCaptureTerminalDisposition?
        ) -> WatchStatusContext {
            Self.context(
                phase: .idle,
                queuedCount: 4,
                asOf: Self.now,
                audioTerminalReason: terminalReason,
                audioTerminalDisposition: terminalDisposition
            )
        }

        let stoppedStatus = status(
            terminalReason: .audioInterrupted,
            terminalDisposition: .detectedStoppedItself
        )
        let noTerminalStatus = status(terminalReason: nil, terminalDisposition: nil)
        let stuckInput = Self.input(
            watchStatus: stoppedStatus,
            nonTerminalCount: 3,
            oldestNonTerminalReceivedAt: Self.now.addingTimeInterval(-1_800)
        )
        let stuckTwin = Self.input(
            watchStatus: noTerminalStatus,
            nonTerminalCount: 3,
            oldestNonTerminalReceivedAt: Self.now.addingTimeInterval(-1_800)
        )
        let waitingInput = Self.input(
            watchStatus: stoppedStatus,
            nonTerminalCount: 2
        )
        let waitingTwin = Self.input(
            watchStatus: noTerminalStatus,
            nonTerminalCount: 2
        )

        let stoppedOverStuck = Self.steadyVerdict(stuckInput)
        let stuckWithoutDisposition = Self.steadyVerdict(stuckTwin)
        let stoppedOverWaiting = Self.steadyVerdict(waitingInput)
        let waitingWithoutDisposition = Self.steadyVerdict(waitingTwin)

        XCTAssertEqual(stoppedOverStuck.kind, .stoppedItself(.audioStoppedItself))
        XCTAssertEqual(stuckWithoutDisposition.kind, .stuck(.orphan))
        XCTAssertEqual(stoppedOverWaiting.kind, .stoppedItself(.audioStoppedItself))
        XCTAssertEqual(waitingWithoutDisposition.kind, .watchWaiting)
    }

    func testSteadyVerdictObservingUsesRequiredCopyAndElapsedSuffix() {
        let input = Self.input(
            watchStatus: Self.context(
                phase: .observing,
                queuedCount: 2,
                transferringCount: 0,
                asOf: Self.now,
                startedAt: Self.now.addingTimeInterval(-125)
            ),
            nonTerminalCount: 3,
            lastReceivedAt: Self.now.addingTimeInterval(-5)
        )

        let verdict = Self.steadyVerdict(input)

        XCTAssertEqual(verdict.kind, .observing)
        XCTAssertEqual(verdict.state, .active)
        XCTAssertEqual(verdict.headline, SourceVocabulary.watchSteadyObservingHeadline)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchObservingSentence(elapsedMinutes: 2))
    }

    func testSteadyVerdictStaleObservingContextDoesNotRenderObservingAtFreshnessBoundary() {
        let input = Self.input(
            watchStatus: Self.context(
                phase: .observing,
                asOf: Self.now.addingTimeInterval(-(WatchPipelineReducer.watchClaimFreshnessWindow + 1)),
                startedAt: Self.now.addingTimeInterval(-300)
            )
        )

        let verdict = Self.steadyVerdict(input)

        XCTAssertNotEqual(verdict.kind, .observing)
        XCTAssertEqual(verdict.kind, .quiet)
    }

    func testSteadyVerdictStoppedItselfSurvivesCaughtUpIncidentState() {
        func input(
            terminalReason: WatchCaptureTerminalReason?,
            terminalDisposition: WatchCaptureTerminalDisposition?
        ) -> WatchPipelineInput {
            Self.input(
                watchStatus: Self.context(
                    phase: .observing,
                    asOf: Self.now.addingTimeInterval(-(WatchRecordingStatus.defaultTTL + 1)),
                    startedAt: Self.now.addingTimeInterval(-60),
                    audioTerminalReason: terminalReason,
                    audioTerminalDisposition: terminalDisposition
                ),
                phoneLedgerSnapshot: .available(Self.ledgerSnapshot(entries: [:]))
            )
        }

        let verdict = Self.steadyVerdict(
            input(
                terminalReason: .audioInterrupted,
                terminalDisposition: .detectedStoppedItself
            ),
            facts: Self.facts(watchAppCheckedIn: true)
        )
        let caughtUpTwin = Self.steadyVerdict(
            input(terminalReason: nil, terminalDisposition: nil),
            facts: Self.facts(watchAppCheckedIn: true)
        )

        XCTAssertEqual(verdict.kind, .stoppedItself(.audioStoppedItself))
        XCTAssertNotEqual(verdict.headline, SourceVocabulary.syncedHeadline)
        XCTAssertEqual(verdict.state, .needsAttention)
        XCTAssertEqual(verdict.headline, WatchNoticeCopy.audioStoppedItself.title)
        XCTAssertEqual(verdict.sentence, WatchNoticeCopy.audioStoppedItself.body)
        XCTAssertNil(verdict.nextStep)
        XCTAssertEqual(caughtUpTwin.kind, .caughtUp)
        XCTAssertEqual(caughtUpTwin.headline, SourceVocabulary.syncedHeadline)
    }

    func testSteadyVerdictReceivingReusesReceivingSubtext() {
        let input = Self.input(
            nonTerminalCount: 2,
            lastReceivedAt: Self.now.addingTimeInterval(-5)
        )

        let verdict = Self.steadyVerdict(input)

        XCTAssertEqual(verdict.kind, .receiving)
        XCTAssertEqual(verdict.state, .active)
        XCTAssertEqual(verdict.headline, SourceVocabulary.watchSteadyReceivingHeadline)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchReceivingNowSubtext)
    }

    func testSteadyVerdictWatchWaitingUsesLeadingFreshWatchPortion() {
        let input = Self.input(
            watchStatus: Self.context(queuedCount: 4, transferringCount: 1, asOf: Self.now),
            nonTerminalCount: 3
        )

        let verdict = Self.steadyVerdict(input)

        XCTAssertEqual(verdict.kind, .watchWaiting)
        XCTAssertEqual(verdict.state, .off)
        XCTAssertEqual(verdict.headline, SourceVocabulary.watchSteadyWatchWaitingHeadline)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchSteadyWatchWaitingSentence(5))
    }

    func testSteadyVerdictPhoneSyncingUsesLeadingPhonePortion() {
        let input = Self.input(
            watchStatus: Self.context(queuedCount: 1, transferringCount: 0, asOf: Self.now),
            nonTerminalCount: 3
        )

        let verdict = Self.steadyVerdict(input)

        XCTAssertEqual(verdict.kind, .phoneSyncing)
        XCTAssertEqual(verdict.state, .off)
        XCTAssertEqual(verdict.headline, SourceVocabulary.watchSteadyPhoneSyncingHeadline)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchSteadyPhoneSyncingSentence(3))
    }

    func testSteadyVerdictCaughtUpRequiresAvailableLedger() {
        let handedID = Self.uuid(900)
        let input = Self.input(
            lifetimeReceived: 1,
            lifetimeHanded: 1,
            phoneLedgerSnapshot: .available(Self.ledgerSnapshot(entries: [
                handedID: Self.ledgerEntry(id: handedID, state: .handed)
            ]))
        )

        let verdict = Self.steadyVerdict(input)
        let unavailable = Self.steadyVerdict(Self.input(lifetimeReceived: 1, lifetimeHanded: 1))

        XCTAssertEqual(verdict.kind, .caughtUp)
        XCTAssertEqual(verdict.state, .off)
        XCTAssertEqual(verdict.headline, SourceVocabulary.syncedHeadline)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchSteadyCaughtUpSentence)
        XCTAssertEqual(unavailable.kind, .quiet)
    }

    func testSteadyVerdictQuietReceivesLedgerUnavailableAndNoSignalFallbacks() {
        let verdict = Self.steadyVerdict(Self.input(), facts: Self.facts(watchAppCheckedIn: true))

        XCTAssertEqual(verdict.kind, .quiet)
        XCTAssertEqual(verdict.state, .off)
        XCTAssertEqual(verdict.headline, SourceVocabulary.watchSteadyQuietHeadline)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchIdleNowSubtext)
        XCTAssertNil(verdict.presenceLine)
        XCTAssertNil(verdict.todayLine)
    }

    func testSteadyVerdictPresenceLineFourOutcomes() {
        let connected = Self.steadyVerdict(
            Self.input(isReachable: true),
            facts: Self.facts(watchAppCheckedIn: false)
        )
        let lastHeardInput = Self.input(
            watchStatus: Self.context(asOf: Self.now.addingTimeInterval(-120)),
            lastReceivedAt: Self.now.addingTimeInterval(-300)
        )
        let lastHeard = Self.steadyVerdict(lastHeardInput)
        let suppressed = Self.steadyVerdict(Self.input(), facts: Self.facts(watchAppCheckedIn: true))
        let neverHeard = Self.steadyVerdict(Self.input(), facts: Self.facts(watchAppCheckedIn: false))

        XCTAssertEqual(connected.presenceLine, SourceVocabulary.watchPresenceConnectedNow)
        XCTAssertEqual(
            lastHeard.presenceLine,
            SourceVocabulary.watchPresenceLastHeard(relative: Self.relativeText(secondsAgo: 120))
        )
        XCTAssertNil(suppressed.presenceLine)
        XCTAssertEqual(neverHeard.presenceLine, SourceVocabulary.watchPresenceNeverHeard)
    }

    func testSteadyVerdictTodayLineLedgerCases() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3_600)!
        let now = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 20,
            hour: 10
        ))!
        let today = now.addingTimeInterval(-300)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let handedTodayID = Self.uuid(910)
        let handedAndDroppedTodayID = Self.uuid(911)
        let handedYesterdayID = Self.uuid(912)
        let ledger = Self.ledgerSnapshot(entries: [
            handedTodayID: Self.ledgerEntry(id: handedTodayID, state: .handed, handedAt: today),
            handedAndDroppedTodayID: Self.ledgerEntry(
                id: handedAndDroppedTodayID,
                state: .handedAndDropped,
                handedAt: today
            ),
            handedYesterdayID: Self.ledgerEntry(id: handedYesterdayID, state: .handed, handedAt: yesterday),
        ])
        let verdict = Self.steadyVerdict(
            Self.input(now: now, phoneLedgerSnapshot: .available(ledger)),
            calendar: calendar
        )

        let nearMidnightNow = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 20,
            hour: 0,
            minute: 30
        ))!
        let afterMidnight = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 20,
            hour: 0,
            minute: 1
        ))!
        let beforeMidnight = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 19,
            hour: 23,
            minute: 59
        ))!
        let afterMidnightID = Self.uuid(913)
        let beforeMidnightID = Self.uuid(914)
        let nearMidnightLedger = Self.ledgerSnapshot(entries: [
            afterMidnightID: Self.ledgerEntry(id: afterMidnightID, state: .handed, handedAt: afterMidnight),
            beforeMidnightID: Self.ledgerEntry(id: beforeMidnightID, state: .handed, handedAt: beforeMidnight),
        ])
        let nearMidnight = Self.steadyVerdict(
            Self.input(now: nearMidnightNow, phoneLedgerSnapshot: .available(nearMidnightLedger)),
            calendar: calendar
        )
        let empty = Self.steadyVerdict(
            Self.input(now: now, phoneLedgerSnapshot: .available(Self.ledgerSnapshot(entries: [:]))),
            calendar: calendar
        )
        let unavailable = Self.steadyVerdict(Self.input(now: now), calendar: calendar)

        XCTAssertEqual(verdict.todayLine, SourceVocabulary.watchTodayHandedLine(2))
        XCTAssertEqual(nearMidnight.todayLine, SourceVocabulary.watchTodayHandedLine(1))
        XCTAssertNil(empty.todayLine)
        XCTAssertNil(unavailable.todayLine)
    }

    func testSteadyVerdictClosedSummaryReadsWaitingBreakdownCounts() {
        let input = Self.input(
            watchStatus: Self.context(queuedCount: 4, transferringCount: 0, asOf: Self.now),
            nonTerminalCount: 2
        )
        let waiting = WatchPipelineReducer.waitingBreakdown(input)

        let verdict = Self.steadyVerdict(input, waiting: waiting)

        XCTAssertEqual(waiting.freshWatchWaitingCount, 4)
        XCTAssertEqual(
            verdict.detailsSummary,
            SourceVocabulary.watchSteadyDetailsSummary(watchWaiting: 4, phoneWaiting: 2)
        )
    }

    func testSteadyVerdictFreshCoherenceMatchesRowSubtextAndClosedSummary() {
        let input = Self.input(
            watchStatus: Self.context(queuedCount: 4, transferringCount: 0, asOf: Self.now),
            nonTerminalCount: 2
        )
        let waiting = WatchPipelineReducer.waitingBreakdown(input)
        let row = Self.rowPresentation(input: input, waiting: waiting)
        let verdict = Self.steadyVerdict(input, waiting: waiting)

        XCTAssertEqual(row.subtext, SourceVocabulary.watchWaitingToSyncFromWatch(4))
        XCTAssertEqual(verdict.kind, .watchWaiting)
        XCTAssertEqual(verdict.sentence, SourceVocabulary.watchSteadyWatchWaitingSentence(4))
        XCTAssertEqual(
            verdict.detailsSummary,
            SourceVocabulary.watchSteadyDetailsSummary(watchWaiting: 4, phoneWaiting: 2)
        )
    }

    func testSteadyVerdictStaleCoherenceGatesWatchCountButDisclosureRowsKeepStaleDetail() {
        let input = Self.input(
            now: Self.now,
            watchStatus: Self.context(queuedCount: 3, transferringCount: 0, asOf: Self.now.addingTimeInterval(-91)),
            phoneLedgerSnapshot: .available(Self.ledgerSnapshot(entries: [:]))
        )
        let waiting = WatchPipelineReducer.waitingBreakdown(input)
        let summary = WatchPipelineReducer.reduce(input)
        let verdict = Self.steadyVerdict(input, waiting: waiting)

        XCTAssertEqual(waiting.freshWatchWaitingCount, 0)
        XCTAssertEqual(verdict.kind, .caughtUp)
        XCTAssertEqual(
            verdict.detailsSummary,
            SourceVocabulary.watchSteadyDetailsSummary(watchWaiting: 0, phoneWaiting: 0)
        )
        XCTAssertEqual(summary.pipelineRows[0].value, "3")
        XCTAssertEqual(
            summary.pipelineRows[0].detail,
            SourceVocabulary.watchPipelineStaleAsOf(Self.relativeText(secondsAgo: 91))
        )
    }

    func testSteadyVerdictStateClassCoherenceMatrix() {
        let observing = Self.input(
            watchStatus: Self.context(phase: .observing, asOf: Self.now, startedAt: Self.now.addingTimeInterval(-60))
        )
        let receiving = Self.input(lastReceivedAt: Self.now.addingTimeInterval(-5))
        let waiting = Self.input(
            watchStatus: Self.context(queuedCount: 3, asOf: Self.now),
            nonTerminalCount: 1
        )
        let phoneSyncing = Self.input(
            watchStatus: Self.context(queuedCount: 1, transferringCount: 0, asOf: Self.now),
            nonTerminalCount: 3
        )
        let caughtUpID = Self.uuid(901)
        let caughtUp = Self.input(
            lifetimeReceived: 1,
            lifetimeHanded: 1,
            phoneLedgerSnapshot: .available(Self.ledgerSnapshot(entries: [
                caughtUpID: Self.ledgerEntry(id: caughtUpID, state: .handed)
            ]))
        )
        let stuck = Self.input(oldestNonTerminalReceivedAt: Self.now.addingTimeInterval(-1_800))

        for input in [observing, receiving] {
            let breakdown = WatchPipelineReducer.waitingBreakdown(input)
            let row = Self.rowPresentation(input: input, waiting: breakdown)
            let verdict = Self.steadyVerdict(input, waiting: breakdown)
            XCTAssertEqual(row.state, .active)
            XCTAssertEqual(verdict.state, .active)
            switch verdict.kind {
            case .observing, .receiving:
                break
            case .stuck, .stoppedItself, .watchWaiting, .phoneSyncing, .caughtUp, .quiet:
                XCTFail("expected on-family verdict for \(verdict.kind)")
            }
        }

        let waitingBreakdown = WatchPipelineReducer.waitingBreakdown(waiting)
        let waitingRow = Self.rowPresentation(input: waiting, waiting: waitingBreakdown)
        let waitingVerdict = Self.steadyVerdict(waiting, waiting: waitingBreakdown)
        XCTAssertNotNil(waitingRow.subtext)
        XCTAssertEqual(waitingVerdict.kind, .watchWaiting)
        XCTAssertEqual(waitingRow.state, .off)
        XCTAssertEqual(waitingVerdict.state, .off)

        let phoneSyncingBreakdown = WatchPipelineReducer.waitingBreakdown(phoneSyncing)
        let phoneSyncingRow = Self.rowPresentation(input: phoneSyncing, waiting: phoneSyncingBreakdown)
        let phoneSyncingVerdict = Self.steadyVerdict(phoneSyncing, waiting: phoneSyncingBreakdown)
        XCTAssertEqual(phoneSyncingRow.state, .off)
        XCTAssertEqual(phoneSyncingVerdict.kind, .phoneSyncing)
        XCTAssertEqual(phoneSyncingVerdict.state, .off)

        let caughtUpBreakdown = WatchPipelineReducer.waitingBreakdown(caughtUp)
        let caughtUpRow = Self.rowPresentation(input: caughtUp, waiting: caughtUpBreakdown)
        let caughtUpVerdict = Self.steadyVerdict(caughtUp, waiting: caughtUpBreakdown)
        XCTAssertEqual(caughtUpRow.state, .off)
        XCTAssertEqual(caughtUpVerdict.kind, .caughtUp)
        XCTAssertEqual(caughtUpVerdict.state, .off)

        let stuckBreakdown = WatchPipelineReducer.waitingBreakdown(stuck)
        let stuckRow = Self.rowPresentation(input: stuck, waiting: stuckBreakdown)
        let stuckVerdict = Self.steadyVerdict(stuck, waiting: stuckBreakdown)
        XCTAssertEqual(stuckRow.state, .needsAttention)
        XCTAssertEqual(stuckVerdict.kind, .stuck(.orphan))
        XCTAssertEqual(stuckVerdict.state, .needsAttention)
    }

    func testDiagnosticsExportForStuckContainsReasonButNoNextStep() {
        let summary = WatchPipelineReducer.reduce(Self.input(
            oldestNonTerminalReceivedAt: Self.now.addingTimeInterval(-1_800)
        ))

        XCTAssertTrue(summary.diagnosticsExportText.contains(SourceVocabulary.watchPipelineOrphanStuckReason))
        XCTAssertFalse(summary.diagnosticsExportText.contains(SourceVocabulary.watchPipelineRelayStuckNextStep))
        XCTAssertFalse(summary.diagnosticsExportText.contains(SourceVocabulary.watchPipelineHandoffStuckNextStep))
        XCTAssertFalse(summary.diagnosticsExportText.contains(SourceVocabulary.watchPipelineOrphanStuckNextStep))
    }

    func testDiagnosticsExportRendersTerminalOutcomeWithoutRawTerminalValues() {
        let input = Self.input(watchStatus: Self.context(
            phase: .observing,
            asOf: Self.now,
            startedAt: Self.now.addingTimeInterval(-60),
            audioTerminalReason: .microphonePermissionRevoked,
            audioTerminalDisposition: .detectedStoppedItself
        ))

        let export = WatchPipelineReducer.reduce(input).diagnosticsExportText

        XCTAssertTrue(export.contains("\(SourceVocabulary.watchStatusLabel): observing · \(Self.relativeText(secondsAgo: 0))"))
        XCTAssertTrue(
            export.contains("\(SourceVocabulary.watchStatusAudioOutcomeLabel): \(WatchNoticeCopy.microphoneAccessNeeded.title)")
        )
        for rawValue in Self.terminalRawValues {
            XCTAssertFalse(export.contains(rawValue), rawValue)
        }
    }

    func testDiagnosticsExportHealthyObservingKeepsPhaseAndOmitsTerminalOutcome() {
        let input = Self.input(watchStatus: Self.context(
            phase: .observing,
            asOf: Self.now,
            startedAt: Self.now.addingTimeInterval(-60)
        ))

        let export = WatchPipelineReducer.reduce(input).diagnosticsExportText

        XCTAssertTrue(export.contains("\(SourceVocabulary.watchStatusLabel): observing · \(Self.relativeText(secondsAgo: 0))"))
        XCTAssertFalse(export.contains("\(SourceVocabulary.watchStatusAudioOutcomeLabel):"))
        XCTAssertFalse(export.contains(WatchNoticeCopy.microphoneAccessNeeded.title))
        for rawValue in Self.terminalRawValues {
            XCTAssertFalse(export.contains(rawValue), rawValue)
        }
    }

    func testRetentionRowsRenderOriginalAudioZeroLengthBucket() {
        let payload = Self.payload(
            activeBacklogCount: 1,
            observations: [],
            originalAudioFileCounts: .available(WatchRelayOriginalFileStateCounts(
                missing: 0,
                readableNonempty: 0,
                zeroLength: 1,
                unreadable: 0
            ))
        )

        let export = WatchPipelineReducer.reduce(Self.input(
            watchDiagnostics: .available(payload, rawEnvelopeByteCount: nil)
        )).diagnosticsExportText

        XCTAssertTrue(export.contains("original audio files:"))
        XCTAssertTrue(export.contains("zero-length 1"))
    }

    func testRetentionRowsAlwaysEmitOriginalAudioEvidenceWhenSummaryAvailable() {
        let payload = Self.payload(
            activeBacklogCount: 1,
            observations: [],
            originalAudioFileCounts: .available(WatchRelayOriginalFileStateCounts(
                missing: 1,
                readableNonempty: 0,
                zeroLength: 0,
                unreadable: 0
            ))
        )

        let export = WatchPipelineReducer.reduce(Self.input(
            watchDiagnostics: .available(payload, rawEnvelopeByteCount: nil)
        )).diagnosticsExportText

        XCTAssertTrue(export.contains("original audio files:"))
        XCTAssertTrue(export.contains("readable-nonempty 0"))
        XCTAssertTrue(export.contains("missing 1"))
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
        XCTAssertTrue(export.contains("relation matched; id "))
    }

    func testSessionHistoryExportRendersNewestFirstRawReasonsAndUnavailableDistinctly() {
        let older = Self.sessionEntry("older", reason: .audioClockStalled, at: Self.now.addingTimeInterval(-20))
        let newer = Self.sessionEntry("newer", reason: .audioRecorderStopped, at: Self.now.addingTimeInterval(-10))
        let payload = Self.payload(
            activeBacklogCount: 0, observations: [],
            sessionHistoryWindow: .available([newer, older]), sessionHistoryDepth: 7,
            lifetimeSessionsStarted: .available(42)
        )
        let rendered = WatchPipelineReducer.reduce(Self.input(
            now: Self.now, watchDiagnostics: .available(payload, rawEnvelopeByteCount: nil)
        )).diagnosticsExportText
        XCTAssertTrue(rendered.contains("watch session history\nsessions in this report: 2\nsessions on the watch not in this report: 5\nsessions started since install: 42"))
        XCTAssertTrue(rendered.contains("outcome: audio-recorder-stopped / detected-stopped-itself"))
        XCTAssertTrue(rendered.contains("outcome: audio-clock-stalled / detected-stopped-itself"))
        XCTAssertLessThan(try! XCTUnwrap(rendered.range(of: "session: 1 of 2")).lowerBound, try! XCTUnwrap(rendered.range(of: "session: 2 of 2")).lowerBound)
        XCTAssertLessThan(try! XCTUnwrap(rendered.range(of: "audio-recorder-stopped")).lowerBound, try! XCTUnwrap(rendered.range(of: "audio-clock-stalled")).lowerBound)

        let empty = WatchPipelineReducer.reduce(Self.input(
            now: Self.now, watchDiagnostics: .available(Self.payload(activeBacklogCount: 0, observations: []), rawEnvelopeByteCount: nil)
        )).diagnosticsExportText
        let unavailablePayload = Self.payload(activeBacklogCount: 0, observations: [], sessionHistoryWindow: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.sessionHistoryUnreadable))
        let unavailable = WatchPipelineReducer.reduce(Self.input(
            now: Self.now, watchDiagnostics: .available(unavailablePayload, rawEnvelopeByteCount: nil)
        )).diagnosticsExportText
        XCTAssertTrue(empty.contains("sessions in this report: 0"))
        XCTAssertFalse(unavailable.contains("sessions in this report: 0"))
        XCTAssertTrue(unavailable.contains(WatchRelayDiagnosticsEnvelopeReason.sessionHistoryUnreadable))
    }
}

private extension WatchPipelineReducerTests {
    static let now = Date(timeIntervalSince1970: 2_000)

    static func context(
        phase: WatchStatusContext.Phase = .idle,
        queuedCount: Int = 0,
        transferringCount: Int = 0,
        asOf: Date = Date(timeIntervalSince1970: 2_000),
        startedAt: Date? = nil,
        audioTerminalReason: WatchCaptureTerminalReason? = nil,
        audioTerminalDisposition: WatchCaptureTerminalDisposition? = nil
    ) -> WatchStatusContext {
        WatchStatusContext(
            phase: phase,
            sessionID: nil,
            startedAt: startedAt,
            asOf: asOf,
            seq: 1,
            queuedCount: queuedCount,
            transferringCount: transferringCount,
            audioTerminalReason: audioTerminalReason,
            audioTerminalDisposition: audioTerminalDisposition
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

    static var terminalRawValues: [String] {
        WatchCaptureTerminalReason.allCases.map(\.rawValue)
            + [
                WatchCaptureTerminalDisposition.ownerStopped,
                .detectedStoppedItself,
                .inferredStoppedItself,
            ].map(\.rawValue)
    }

    static func facts(
        watchAppCheckedIn: Bool = true,
        segmentFileReceived: Bool = false
    ) -> WatchSourceFacts.Snapshot {
        WatchSourceFacts.Snapshot(
            watchAppCheckedIn: watchAppCheckedIn,
            segmentFileReceived: segmentFileReceived,
            installTapped: false,
            firstSegmentCelebrationShown: false
        )
    }

    static func steadyVerdict(
        _ input: WatchPipelineInput,
        waiting: WatchWaitingBreakdown? = nil,
        facts: WatchSourceFacts.Snapshot = WatchSourceFacts.Snapshot(
            watchAppCheckedIn: true,
            segmentFileReceived: false,
            installTapped: false,
            firstSegmentCelebrationShown: false
        ),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> WatchSteadyVerdict {
        WatchSteadyVerdictReducer.reduce(
            input,
            waiting: waiting ?? WatchPipelineReducer.waitingBreakdown(input),
            facts: facts,
            calendar: calendar
        )
    }

    static func rowPresentation(
        input: WatchPipelineInput,
        waiting: WatchWaitingBreakdown
    ) -> PhoneWatchSourcePresentation {
        let recordingStatus = watchRecordingStatus(
            context: input.watchStatus,
            now: input.now,
            lastReceivedAt: input.lastReceivedAt
        )
        return phoneWatchSourcePresentation(
            lane: phoneWatchSourceLane(
                session: .activated(.installedActive),
                flow: WatchInstalledFlowInput(
                    stuck: WatchPipelineReducer.stuckState(input),
                    recordingStatus: recordingStatus,
                    waiting: waiting
                )
            )
        )
    }

    static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    static func payload(
        activeBacklogCount: Int,
        observations: [WatchRelayTransferObservation],
        omittedObservationCount: Int = 0,
        sessionHistoryWindow: DiagnosticAvailability<[WatchCaptureSessionHistoryEntry]> = .available([]),
        sessionHistoryDepth: Int = 0,
        lifetimeSessionsStarted: DiagnosticAvailability<Int> = .available(0),
        originalAudioFileCounts: DiagnosticAvailability<WatchRelayOriginalFileStateCounts> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        )
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
                oldestActiveEnqueueAgeSeconds: .available(nil),
                originalAudioFileCounts: originalAudioFileCounts
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
            omittedObservationCount: omittedObservationCount,
            sessionHistoryWindow: sessionHistoryWindow,
            lifetimeSessionsStarted: lifetimeSessionsStarted,
            sessionHistoryCounterEpoch: .available("epoch"),
            sessionHistoryDepth: sessionHistoryDepth
        )
    }

    static func sessionEntry(_ id: String, reason: WatchCaptureTerminalReason, at: Date) -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(sessionID: id, startedAt: at.addingTimeInterval(-30), terminalAt: at,
            terminalReason: reason, terminalDisposition: .detectedStoppedItself, startRefusalReason: nil,
            settingsRoute: nil, noticeOwed: false, noticeDecision: "schedule", noticeDelivered: true,
            notificationAuthorizationStatus: .authorized, notificationAlertSetting: .enabled, wristAlertAssurance: .willTap,
            audioArmed: true, audioSessionIsActive: true, locationArmed: false, segmentsProduced: 2,
            batteryLevelAtEnd: 0.75, batteryStateAtEnd: "unplugged", lowPowerModeEnabledAtEnd: false,
            thermalStateAtEnd: "nominal", lastVerifiedAudioAt: at, lastAudioCurrentTime: 12.5,
            zeroAudioCurrentTimeObservationCount: 3, locationAdvisory: nil, persistenceAdvisory: nil)
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
        state: WatchSegmentLedgerEntryState,
        receivedAt receivedAtOverride: Date? = nil,
        handedAt handedAtOverride: Date? = nil,
        droppedAt droppedAtOverride: Date? = nil
    ) -> WatchSegmentLedgerEntrySnapshot {
        let receivedAt = state == .dropped ? nil : receivedAtOverride ?? Self.now.addingTimeInterval(-30)
        let handedAt = state == .handed || state == .handedAndDropped
            ? handedAtOverride ?? Self.now.addingTimeInterval(-20)
            : nil
        let droppedAt = state == .dropped || state == .handedAndDropped
            ? droppedAtOverride ?? Self.now.addingTimeInterval(-10)
            : nil
        return WatchSegmentLedgerEntrySnapshot(
            segmentID: id,
            state: state,
            receivedAt: receivedAt,
            handedAt: handedAt,
            droppedAt: droppedAt,
            receivedAgeSeconds: receivedAt.map { Self.now.timeIntervalSince($0) },
            handedAgeSeconds: handedAt.map { Self.now.timeIntervalSince($0) },
            droppedAgeSeconds: droppedAt.map { Self.now.timeIntervalSince($0) }
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
