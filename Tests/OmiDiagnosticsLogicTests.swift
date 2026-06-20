// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiDiagnosticsLogicTests: XCTestCase {
    func testDecodeErrorRateHandlesZeroAndNonzeroTotals() {
        XCTAssertEqual(OmiDiagnosticsLogic.decodeErrorRate(ok: 0, errors: 0), 0)
        XCTAssertEqual(OmiDiagnosticsLogic.decodeErrorRate(ok: 3, errors: 1), 0.25, accuracy: 0.0001)
    }

    func testGapSummaryCountsContiguousDisconnectGap() {
        let start = Date(timeIntervalSince1970: 100)
        let summary = OmiDiagnosticsLogic.gapSummary(from: [
            OmiDiagnosticsGapProbe(timestamp: start, connected: false),
            OmiDiagnosticsGapProbe(timestamp: start.addingTimeInterval(10), connected: false),
            OmiDiagnosticsGapProbe(timestamp: start.addingTimeInterval(20), connected: true, connectedSince: start.addingTimeInterval(20))
        ])

        XCTAssertEqual(summary.disconnectGapCount, 1)
        XCTAssertEqual(summary.disconnectGapSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(summary.connectedSilentGapCount, 0)
        XCTAssertEqual(summary.connectedSilentGapSeconds, 0, accuracy: 0.001)
    }

    func testGapSummaryCountsConnectedSilentGapBeyondThreshold() {
        let start = Date(timeIntervalSince1970: 200)
        let summary = OmiDiagnosticsLogic.gapSummary(from: [
            OmiDiagnosticsGapProbe(timestamp: start, connected: true, connectedSince: start, lastAudioAt: nil),
            OmiDiagnosticsGapProbe(timestamp: start.addingTimeInterval(40), connected: true, connectedSince: start, lastAudioAt: nil),
            OmiDiagnosticsGapProbe(timestamp: start.addingTimeInterval(70), connected: true, connectedSince: start, lastAudioAt: nil)
        ])

        XCTAssertEqual(summary.disconnectGapCount, 0)
        XCTAssertEqual(summary.connectedSilentGapCount, 1)
        XCTAssertEqual(summary.connectedSilentGapSeconds, 40, accuracy: 0.001)
    }

    func testGapSummaryLeavesNormalConnectedStreamingRunClear() {
        let start = Date(timeIntervalSince1970: 300)
        let summary = OmiDiagnosticsLogic.gapSummary(from: [
            OmiDiagnosticsGapProbe(timestamp: start, connected: true, connectedSince: start, lastAudioAt: start),
            OmiDiagnosticsGapProbe(timestamp: start.addingTimeInterval(10), connected: true, connectedSince: start, lastAudioAt: start.addingTimeInterval(10)),
            OmiDiagnosticsGapProbe(timestamp: start.addingTimeInterval(20), connected: true, connectedSince: start, lastAudioAt: start.addingTimeInterval(20)),
            OmiDiagnosticsGapProbe(timestamp: start.addingTimeInterval(30), connected: true, connectedSince: start, lastAudioAt: start.addingTimeInterval(30))
        ])

        XCTAssertEqual(summary.disconnectGapCount, 0)
        XCTAssertEqual(summary.disconnectGapSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(summary.connectedSilentGapCount, 0)
        XCTAssertEqual(summary.connectedSilentGapSeconds, 0, accuracy: 0.001)
    }

    func testUptimeAccumulatorConnectedFraction() throws {
        let start = Date(timeIntervalSince1970: 400)
        var uptime = OmiUptimeAccumulator()

        uptime.noteConnected(at: start.addingTimeInterval(10))
        uptime.noteDisconnected(at: start.addingTimeInterval(40))

        XCTAssertEqual(
            try XCTUnwrap(uptime.connectedFraction(since: start, asOf: start.addingTimeInterval(60))),
            0.5,
            accuracy: 0.001
        )
    }

    func testExportSummaryContainsRequiredMetricLines() {
        let start = Date(timeIntervalSince1970: 500)
        let payload = OmiDiagnosticsPayload(
            firstObservedAt: start,
            uptime: OmiDiagnosticsPayload.UptimeSnapshot(
                connectedSince: start,
                accumulatedConnectedSeconds: 30
            ),
            reconnectEvents: [
                OmiDiagnosticsPayload.ReconnectEvent(
                    timestamp: start.addingTimeInterval(10),
                    reason: "link lost",
                    appStateAtDrop: "foreground",
                    timeToReconnect: 2.5
                )
            ],
            decodeCounters: OmiDiagnosticsPayload.DecodeCounters(
                ok: 9,
                errors: 1,
                gaps: 2,
                outOfOrder: 3
            ),
            pendantBatteryTrend: [
                OmiDiagnosticsPayload.PendantBatterySample(timestamp: start, level: 88)
            ],
            phoneSamples: [
                OmiDiagnosticsPayload.PhoneSample(timestamp: start, batteryLevel: 0.5, thermalState: "nominal")
            ],
            gapTallies: OmiDiagnosticsPayload.GapTallies(
                disconnectGapCount: 1,
                disconnectGapSeconds: 12,
                connectedSilentGapCount: 1,
                connectedSilentGapSeconds: 8
            )
        )

        let report = OmiDiagnosticsLogic.exportSummary(payload: payload, asOf: start.addingTimeInterval(60))

        for requiredLine in [
            "omi diagnostics",
            "generated:",
            "uptime:",
            "connected time:",
            "reconnects:",
            "last reconnect:",
            "disconnect gaps:",
            "connected-without-audio gaps:",
            "decode error rate:",
            "decode frames:",
            "audio gaps:",
            "out of order frames:",
            "pendant battery:",
            "phone battery:",
            "phone thermal state:"
        ] {
            XCTAssertTrue(report.contains(requiredLine), requiredLine)
        }
        XCTAssertTrue(report.hasSuffix("\n"))
    }
}
