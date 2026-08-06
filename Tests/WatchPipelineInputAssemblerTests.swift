// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class WatchPipelineInputAssemblerTests: XCTestCase {
    func testPhoneSessionHistoryInputDistinguishesLostAndFullyReceivedSessions() throws {
        let entry = WatchCaptureSessionHistoryEntry(
            sessionID: "session",
            startedAt: Date(timeIntervalSince1970: 1),
            terminalAt: Date(timeIntervalSince1970: 2),
            terminalReason: .audioClockStalled,
            terminalDisposition: .detectedStoppedItself,
            startRefusalReason: nil,
            settingsRoute: nil,
            noticeOwed: false,
            noticeDecision: "schedule",
            noticeDelivered: true,
            notificationAuthorizationStatus: .authorized,
            notificationAlertSetting: .enabled,
            wristAlertAssurance: .willTap,
            audioArmed: true,
            audioSessionIsActive: true,
            locationArmed: false,
            segmentsProduced: 1,
            batteryLevelAtEnd: nil,
            batteryStateAtEnd: nil,
            lowPowerModeEnabledAtEnd: nil,
            thermalStateAtEnd: nil,
            lastVerifiedAudioAt: nil,
            lastAudioCurrentTime: nil,
            zeroAudioCurrentTimeObservationCount: nil,
            locationAdvisory: nil,
            persistenceAdvisory: nil
        )
        let lost = WatchPhoneSessionHistorySnapshot(
            entries: [entry],
            retainedCount: 1,
            prunedForAgeTotal: 2,
            distinctMergedTotal: 12,
            retentionDays: 7,
            adjustedWatchStarted: .available(54),
            counterEpoch: .available("epoch"),
            baselineEpoch: "epoch",
            baselineAdjustedWatchStarted: 49,
            baselineDistinctMerged: 10
        )

        let lostInput = try XCTUnwrap(WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(lost)).value)
        XCTAssertEqual(lostInput.entries, [entry])
        XCTAssertEqual(lostInput.retainedCount, 1)
        XCTAssertEqual(lostInput.retentionDays, 7)
        XCTAssertEqual(lostInput.droppedAsOlderThanRetentionWindow, 2)
        XCTAssertEqual(lostInput.sessionsNotReceived, .available(3))

        let fullyReceived = WatchPhoneSessionHistorySnapshot(
            entries: [entry],
            retainedCount: 1,
            prunedForAgeTotal: 2,
            distinctMergedTotal: 12,
            retentionDays: 7,
            adjustedWatchStarted: .available(51),
            counterEpoch: .available("epoch"),
            baselineEpoch: "epoch",
            baselineAdjustedWatchStarted: 49,
            baselineDistinctMerged: 10
        )
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(fullyReceived)).value?.sessionsNotReceived,
            .available(0)
        )
    }

    func testPhoneSessionHistoryInputMarksUnavailableCountersAndNegativeDeltasUnavailable() throws {
        let unavailable = WatchPhoneSessionHistorySnapshot(
            entries: [], retainedCount: 0, prunedForAgeTotal: 0, distinctMergedTotal: 0, retentionDays: 7,
            adjustedWatchStarted: .unavailable(reason: "counter missing"), counterEpoch: .unavailable(reason: "counter missing"),
            baselineEpoch: nil, baselineAdjustedWatchStarted: nil, baselineDistinctMerged: nil
        )
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(unavailable)).value?.sessionsNotReceived.unavailableReason,
            "counter missing"
        )

        let negative = WatchPhoneSessionHistorySnapshot(
            entries: [], retainedCount: 0, prunedForAgeTotal: 0, distinctMergedTotal: 12, retentionDays: 7,
            adjustedWatchStarted: .available(49), counterEpoch: .available("epoch"),
            baselineEpoch: "epoch", baselineAdjustedWatchStarted: 50, baselineDistinctMerged: 10
        )
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(negative)).value?.sessionsNotReceived.unavailableReason,
            SourceVocabulary.watchDiagnosticsUnavailable
        )

        let epochMismatch = WatchPhoneSessionHistorySnapshot(
            entries: [], retainedCount: 0, prunedForAgeTotal: 0, distinctMergedTotal: 12, retentionDays: 7,
            adjustedWatchStarted: .available(52), counterEpoch: .available("new"),
            baselineEpoch: "old", baselineAdjustedWatchStarted: 50, baselineDistinctMerged: 10
        )
        XCTAssertEqual(
            WatchPipelineInputReader.phoneSessionHistoryInput(from: .available(epochMismatch)).value?.sessionsNotReceived.unavailableReason,
            SourceVocabulary.watchDiagnosticsUnavailable
        )
    }
}
