// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class BLEDrainReconcileTests: XCTestCase {
    func testVoicedSecondsUsesSixteenKilohertzSamples() {
        XCTAssertEqual(BLEDrainReconcileLogic.voicedSeconds(sampleCount: 0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BLEDrainReconcileLogic.voicedSeconds(sampleCount: 16_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(BLEDrainReconcileLogic.voicedSeconds(sampleCount: 24_000), 1.5, accuracy: 0.0001)
    }

    func testMakeRecordPreservesRawFields() {
        let normal = BLEDrainReconcileLogic.makeRecord(
            fileNumber: 7,
            epoch: 1_704_067_200,
            bytes: 790_240,
            sampleCount: 24_000,
            decodeOK: 120,
            decodeErrors: 1,
            status: "complete"
        )
        XCTAssertEqual(normal.fileNumber, 7)
        XCTAssertEqual(normal.epoch, 1_704_067_200)
        XCTAssertEqual(normal.bytes, 790_240)
        XCTAssertEqual(normal.sampleCount, 24_000)
        XCTAssertEqual(normal.decodeOK, 120)
        XCTAssertEqual(normal.decodeErrors, 1)
        XCTAssertEqual(normal.status, "complete")

        let epochZero = BLEDrainReconcileLogic.makeRecord(
            fileNumber: 8,
            epoch: 0,
            bytes: 16_000,
            sampleCount: 16_000,
            decodeOK: 50,
            decodeErrors: 0,
            status: "stopped"
        )
        XCTAssertEqual(epochZero.epoch, 0)

        let noFrames = BLEDrainReconcileLogic.makeRecord(
            fileNumber: nil,
            epoch: nil,
            bytes: 0,
            sampleCount: 0,
            decodeOK: 0,
            decodeErrors: 0,
            status: "stopped"
        )
        XCTAssertNil(noFrames.fileNumber)
        XCTAssertNil(noFrames.epoch)
    }

    func testRenderSummaryReturnsExactEmptyState() {
        XCTAssertEqual(
            BLEDrainReconcileLogic.renderSummary(records: []),
            """
            solstone-swift sd-card drain reconciliation
            records: 0
            ---
            no sd-card drain reconciliation records yet
            """
        )
    }

    func testRenderSummaryIncludesRecordsInInsertionOrderAndDerivedFields() throws {
        let records = [
            BLEDrainReconcileLogic.makeRecord(
                fileNumber: 7,
                epoch: 1_704_067_200,
                bytes: 790_240,
                sampleCount: 24_000,
                decodeOK: 120,
                decodeErrors: 1,
                status: "complete"
            ),
            BLEDrainReconcileLogic.makeRecord(
                fileNumber: 8,
                epoch: 0,
                bytes: 16_000,
                sampleCount: 16_000,
                decodeOK: 50,
                decodeErrors: 0,
                status: "stopped"
            ),
            BLEDrainReconcileLogic.makeRecord(
                fileNumber: nil,
                epoch: nil,
                bytes: 0,
                sampleCount: 0,
                decodeOK: 0,
                decodeErrors: 0,
                status: "stopped"
            )
        ]

        let summary = BLEDrainReconcileLogic.renderSummary(records: records)

        let fileSevenRange = try XCTUnwrap(summary.range(of: "file#: 7"))
        let fileEightRange = try XCTUnwrap(summary.range(of: "file#: 8"))
        XCTAssertLessThan(fileSevenRange.lowerBound, fileEightRange.lowerBound)
        XCTAssertTrue(summary.contains("voiced seconds (decoded-frame seconds, not wall-clock): 1.5"), summary)
        XCTAssertTrue(summary.contains("2024-01-01T00:00:00Z"), summary)
        XCTAssertTrue(summary.contains("creation epoch: 0 (utc: 1970-01-01T00:00:00Z)"), summary)
        XCTAssertTrue(summary.contains("epoch flag: pre-2021 / possible RTC-unsynced"), summary)
        XCTAssertTrue(summary.contains("file#: unknown"), summary)
        XCTAssertTrue(summary.contains("creation epoch: none (no frames)"), summary)

        let blocks = summary.components(separatedBy: "\n---\n")
        let nilEpochBlock = try XCTUnwrap(blocks.first { $0.contains("file#: unknown") })
        XCTAssertFalse(nilEpochBlock.contains("epoch flag:"), nilEpochBlock)
    }
}
