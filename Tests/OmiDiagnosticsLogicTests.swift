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

    func testAccumulatedCounterHandlesRisingEqualAndResetValues() {
        let rising = OmiDiagnosticsLogic.accumulatedCounter(lifetime: 5, lastSeen: 5, incoming: 9)
        XCTAssertEqual(rising.lifetime, 9)
        XCTAssertEqual(rising.lastSeen, 9)

        let equal = OmiDiagnosticsLogic.accumulatedCounter(lifetime: 9, lastSeen: 9, incoming: 9)
        XCTAssertEqual(equal.lifetime, 9)
        XCTAssertEqual(equal.lastSeen, 9)

        let reset = OmiDiagnosticsLogic.accumulatedCounter(lifetime: 9, lastSeen: 9, incoming: 3)
        XCTAssertEqual(reset.lifetime, 12)
        XCTAssertEqual(reset.lastSeen, 3)
    }

    func testAppStateBucketUsesForegroundLockedBackgroundOrder() {
        XCTAssertEqual(
            OmiDiagnosticsLogic.appStateBucket(
                applicationStateIsActive: true,
                isProtectedDataAvailable: false
            ),
            "foreground"
        )
        XCTAssertEqual(
            OmiDiagnosticsLogic.appStateBucket(
                applicationStateIsActive: false,
                isProtectedDataAvailable: false
            ),
            "locked"
        )
        XCTAssertEqual(
            OmiDiagnosticsLogic.appStateBucket(
                applicationStateIsActive: false,
                isProtectedDataAvailable: true
            ),
            "background"
        )
    }

    func testSubscribeLatencyBreakdownSumsStatesAndNormalizesUnknownToBackground() {
        let start = Date(timeIntervalSince1970: 50)
        let breakdown = OmiDiagnosticsLogic.subscribeLatencyBreakdown([
            OmiDiagnosticsPayload.SubscribeLatencySample(
                timestamp: start,
                latencySeconds: 1.25,
                appState: "foreground"
            ),
            OmiDiagnosticsPayload.SubscribeLatencySample(
                timestamp: start.addingTimeInterval(1),
                latencySeconds: 2,
                appState: "locked"
            ),
            OmiDiagnosticsPayload.SubscribeLatencySample(
                timestamp: start.addingTimeInterval(2),
                latencySeconds: 3,
                appState: "inactive"
            )
        ])

        XCTAssertEqual(breakdown.sampleCount, 3)
        XCTAssertEqual(breakdown.totalSeconds, 6.25, accuracy: 0.001)
        XCTAssertEqual(breakdown.foregroundSeconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(breakdown.lockedSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(breakdown.backgroundSeconds, 3, accuracy: 0.001)
    }

    func testAddingSilentAttributionTreatsNilAsZeroAndUnknownAsBackground() {
        var tallies = OmiDiagnosticsPayload.GapTallies(
            connectedSilentGapCount: 1,
            connectedSilentGapSeconds: 75
        )
        tallies = OmiDiagnosticsLogic.addingSilentAttribution(
            to: tallies,
            elapsed: 30,
            appState: "foreground"
        )
        tallies = OmiDiagnosticsLogic.addingSilentAttribution(
            to: tallies,
            elapsed: 40,
            appState: "background"
        )
        tallies = OmiDiagnosticsLogic.addingSilentAttribution(
            to: tallies,
            elapsed: 5,
            appState: "inactive"
        )

        XCTAssertEqual(tallies.connectedSilentForegroundSeconds, 30)
        XCTAssertEqual(tallies.connectedSilentBackgroundSeconds, 45)
        XCTAssertNil(tallies.connectedSilentLockedSeconds)
        let bucketTotal = (tallies.connectedSilentForegroundSeconds ?? 0)
            + (tallies.connectedSilentBackgroundSeconds ?? 0)
            + (tallies.connectedSilentLockedSeconds ?? 0)
        XCTAssertEqual(bucketTotal, tallies.connectedSilentGapSeconds, accuracy: 0.001)
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

    func testDiagnosticRowsExposeFiveRawStatsInOrder() {
        let start = Date(timeIntervalSince1970: 450)
        let payload = OmiDiagnosticsPayload(
            firstObservedAt: start,
            uptime: OmiDiagnosticsPayload.UptimeSnapshot(
                connectedSince: nil,
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
            pendantSignalTrend: [
                OmiDiagnosticsPayload.PendantSignalSample(timestamp: start, level: -60)
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

        let rows = OmiDiagnosticsLogic.diagnosticRows(payload: payload, asOf: start.addingTimeInterval(60))

        XCTAssertEqual(rows.map(\.label), [
            "uptime",
            "reconnects",
            "disconnect gaps",
            "connected-without-audio gaps",
            "decode error rate"
        ])
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { !$0.value.isEmpty })
        XCTAssertEqual(rows.first(where: { $0.label == "uptime" })?.value, "50.0%")
        XCTAssertEqual(rows.first(where: { $0.label == "reconnects" })?.value, "1")
        XCTAssertEqual(rows.first(where: { $0.label == "decode error rate" })?.value, "10.0%")
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
            "disconnect profile:",
            "disconnect gaps:",
            "connected-without-audio gaps:",
            "decode error rate:",
            "decode frames:",
            "audio gaps:",
            "out of order frames:",
            "pendant battery:",
            "pendant signal:",
            "phone battery:",
            "phone thermal state:",
            "unrecoverable connect-to-subscribe:",
            "connected-without-audio buckets:",
            "disconnect window:",
            "voiced-seconds received live:",
            "recovery note:",
            "silence note:",
            "storage backlog:",
            "supporting readings: raw millivolts are not exposed over BLE on 3.0.19",
            "supporting readings: reboot count",
            "supporting readings: mtu connect"
        ] {
            XCTAssertTrue(report.contains(requiredLine), requiredLine)
        }
        XCTAssertTrue(report.hasSuffix("\n"))
    }

    func testExportSummaryReportsPhoneBatteryDrainForUnpluggedSamples() {
        let start = Date(timeIntervalSince1970: 600)
        let report = Self.report(phoneSamples: [
            Self.phoneSample(level: 1.0, state: "unplugged", at: start),
            Self.phoneSample(level: 0.91, state: "unplugged", at: start.addingTimeInterval(3_600))
        ], asOf: start.addingTimeInterval(3_600))

        XCTAssertTrue(report.contains("phone battery: 100%→91%, drain 9.0%/hr (2 samples)"), report)
    }

    func testExportSummaryExcludesChargingIntervalsFromPhoneBatteryDrain() {
        let start = Date(timeIntervalSince1970: 700)
        let report = Self.report(phoneSamples: [
            Self.phoneSample(level: 1.0, state: "unplugged", at: start),
            Self.phoneSample(level: 0.90, state: "unplugged", at: start.addingTimeInterval(3_600)),
            Self.phoneSample(level: 0.95, state: "charging", at: start.addingTimeInterval(7_200)),
            Self.phoneSample(level: 0.80, state: "unplugged", at: start.addingTimeInterval(10_800))
        ], asOf: start.addingTimeInterval(10_800))

        XCTAssertTrue(report.contains("phone battery: 100%→80%, drain 10.0%/hr (4 samples)"), report)
    }

    func testExportSummaryReportsNoOnBatteryIntervalForChargingOrUnknownPhoneState() {
        let start = Date(timeIntervalSince1970: 800)
        let chargingReport = Self.report(phoneSamples: [
            Self.phoneSample(level: 1.0, state: "charging", at: start),
            Self.phoneSample(level: 0.90, state: "charging", at: start.addingTimeInterval(3_600))
        ], asOf: start.addingTimeInterval(3_600))
        let unknownStateReport = Self.report(phoneSamples: [
            Self.phoneSample(level: 1.0, state: "unknown", at: start),
            Self.phoneSample(level: 0.90, state: "unknown", at: start.addingTimeInterval(3_600))
        ], asOf: start.addingTimeInterval(3_600))

        XCTAssertTrue(
            chargingReport.contains("phone battery: 100%→90%, no on-battery interval (2 samples)"),
            chargingReport
        )
        XCTAssertTrue(
            unknownStateReport.contains("phone battery: 100%→90%, no on-battery interval (2 samples)"),
            unknownStateReport
        )
    }

    func testExportSummaryReportsUnknownPhoneBatteryWhenLevelsAreMissing() {
        let start = Date(timeIntervalSince1970: 900)
        let report = Self.report(phoneSamples: [
            Self.phoneSample(level: nil, state: "unplugged", at: start),
            Self.phoneSample(level: nil, state: "unplugged", at: start.addingTimeInterval(3_600))
        ], asOf: start.addingTimeInterval(3_600))

        XCTAssertTrue(report.contains("phone battery: unknown (2 samples)"), report)
    }

    func testExportSummaryReportsRateUnavailableForSinglePhoneBatterySample() {
        let start = Date(timeIntervalSince1970: 1_000)
        let report = Self.report(phoneSamples: [
            Self.phoneSample(level: 0.87, state: "unplugged", at: start)
        ], asOf: start.addingTimeInterval(3_600))

        XCTAssertTrue(report.contains("phone battery: 87%→87%, rate unavailable (1 samples)"), report)
    }

    func testExportSummaryClampsNonMonotonicPhoneBatteryDrainToZero() {
        let start = Date(timeIntervalSince1970: 1_100)
        let report = Self.report(phoneSamples: [
            Self.phoneSample(level: 0.90, state: "unplugged", at: start),
            Self.phoneSample(level: 0.95, state: "unplugged", at: start.addingTimeInterval(3_600))
        ], asOf: start.addingTimeInterval(3_600))

        XCTAssertTrue(report.contains("phone battery: 90%→95%, drain 0.0%/hr (2 samples)"), report)
    }

    func testExportSummaryReportsPendantBatteryDrain() {
        let start = Date(timeIntervalSince1970: 1_200)
        let report = Self.report(pendantBatteryTrend: [
            OmiDiagnosticsPayload.PendantBatterySample(timestamp: start, level: 88),
            OmiDiagnosticsPayload.PendantBatterySample(timestamp: start.addingTimeInterval(3_600), level: 82)
        ], asOf: start.addingTimeInterval(3_600))

        XCTAssertTrue(report.contains("pendant battery: 88%→82%, drain 6.0%/hr (2 samples)"), report)
    }

    func testDisconnectProfileTextSummarizesAllDisconnectEvents() {
        let start = Date(timeIntervalSince1970: 1_300)
        let events = [
            OmiDiagnosticsPayload.ReconnectEvent(
                timestamp: start,
                reason: "link lost",
                appStateAtDrop: "background",
                timeToReconnect: 1
            ),
            OmiDiagnosticsPayload.ReconnectEvent(
                timestamp: start.addingTimeInterval(10),
                reason: "link lost",
                appStateAtDrop: "background",
                timeToReconnect: 2
            ),
            OmiDiagnosticsPayload.ReconnectEvent(
                timestamp: start.addingTimeInterval(20),
                reason: "link lost",
                appStateAtDrop: "foreground",
                timeToReconnect: 3
            ),
            OmiDiagnosticsPayload.ReconnectEvent(
                timestamp: start.addingTimeInterval(30),
                reason: "timeout",
                appStateAtDrop: "background",
                timeToReconnect: nil
            )
        ]

        XCTAssertEqual(
            OmiDiagnosticsLogic.disconnectProfileText(events),
            "4 disconnects (3 reconnected, 1 unpaired); link lost/background ×2, link lost/foreground ×1, timeout/background ×1"
        )
    }

    func testDisconnectProfileTextReportsNoneForEmptyEvents() {
        XCTAssertEqual(OmiDiagnosticsLogic.disconnectProfileText([]), "none")
    }

    func testDisconnectWindowLinesRenderClosedOpenAndCapacityCaution() {
        let start = Date(timeIntervalSince1970: 1_400)
        let lines = OmiDiagnosticsLogic.disconnectWindowLines(
            events: [
                OmiDiagnosticsPayload.ReconnectEvent(
                    timestamp: start,
                    reason: "link lost",
                    appStateAtDrop: "background",
                    timeToReconnect: 5
                ),
                OmiDiagnosticsPayload.ReconnectEvent(
                    timestamp: start.addingTimeInterval(10),
                    reason: "timeout",
                    appStateAtDrop: "locked",
                    timeToReconnect: nil
                )
            ],
            capacity: 2,
            asOf: start.addingTimeInterval(20)
        )

        XCTAssertEqual(lines.first, "disconnect windows: showing most recent 2 retained disconnects")
        XCTAssertTrue(lines[1].contains("reason: link lost, app state: background"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines[1].contains("[1970-01-01T00:23:20Z,1970-01-01T00:23:25Z]"), lines[1])
        XCTAssertTrue(lines[2].contains("[1970-01-01T00:23:30Z,open]"), lines[2])
        XCTAssertTrue(lines[2].contains("reason: timeout, app state: locked"), lines[2])
    }

    func testVoicedSecondsUsesTwentyMillisecondsPerDecodeOKFrame() {
        XCTAssertEqual(OmiDiagnosticsLogic.voicedSeconds(decodeOK: 9), 0.18, accuracy: 0.0001)
    }

    func testStorageBacklogProjectionHandlesMissingSingleGrowthAndFullCases() throws {
        let start = Date(timeIntervalSince1970: 1_500)

        XCTAssertNil(OmiDiagnosticsLogic.storageBacklogProjection(samples: []))

        let single = try XCTUnwrap(OmiDiagnosticsLogic.storageBacklogProjection(samples: [
            OmiDiagnosticsPayload.StorageBacklogSample(
                timestamp: start,
                usedBytes: 100,
                rawHex: "64000000",
                fileCountUnconfirmed: 2
            )
        ], capacityBytes: 500))
        XCTAssertEqual(single.startUsedBytes, 100)
        XCTAssertEqual(single.endUsedBytes, 100)
        XCTAssertEqual(single.growthBytes, 0)
        XCTAssertNil(single.timeToFullSeconds)

        let growing = try XCTUnwrap(OmiDiagnosticsLogic.storageBacklogProjection(samples: [
            OmiDiagnosticsPayload.StorageBacklogSample(
                timestamp: start,
                usedBytes: 100,
                rawHex: "64000000",
                fileCountUnconfirmed: 2
            ),
            OmiDiagnosticsPayload.StorageBacklogSample(
                timestamp: start.addingTimeInterval(100),
                usedBytes: 200,
                rawHex: "c8000000",
                fileCountUnconfirmed: 3
            )
        ], capacityBytes: 500))
        XCTAssertEqual(growing.growthBytes, 100)
        XCTAssertEqual(growing.fileCountUnconfirmed, 3)
        XCTAssertEqual(try XCTUnwrap(growing.timeToFullSeconds), 300, accuracy: 0.001)

        let full = try XCTUnwrap(OmiDiagnosticsLogic.storageBacklogProjection(samples: [
            OmiDiagnosticsPayload.StorageBacklogSample(
                timestamp: start,
                usedBytes: 400,
                rawHex: "90010000",
                fileCountUnconfirmed: 2
            ),
            OmiDiagnosticsPayload.StorageBacklogSample(
                timestamp: start.addingTimeInterval(100),
                usedBytes: 500,
                rawHex: "f4010000",
                fileCountUnconfirmed: 3
            )
        ], capacityBytes: 500))
        XCTAssertNil(full.timeToFullSeconds)
    }

    func testPendantRebootPredicateDetectsLargeDropsAndSentinelCrossing() {
        XCTAssertTrue(OmiDiagnosticsLogic.isPendantReboot(epochBefore: 2_000, epochAfter: 1_000))
        XCTAssertTrue(OmiDiagnosticsLogic.isPendantReboot(epochBefore: 1_700_000_000, epochAfter: 1_000))
        XCTAssertFalse(OmiDiagnosticsLogic.isPendantReboot(epochBefore: 2_000, epochAfter: 1_800))
        XCTAssertFalse(OmiDiagnosticsLogic.isPendantReboot(epochBefore: 2_000, epochAfter: 2_100))
    }

    func testPendantRebootEventsUseMaxBaselineAndResetAfterEvent() {
        let start = Date(timeIntervalSince1970: 1_600)
        let events = OmiDiagnosticsLogic.pendantRebootEvents(from: [
            (observedAt: start, epoch: 1_000),
            (observedAt: start.addingTimeInterval(1), epoch: 1_100),
            (observedAt: start.addingTimeInterval(2), epoch: 1_050),
            (observedAt: start.addingTimeInterval(3), epoch: 700),
            (observedAt: start.addingTimeInterval(4), epoch: 800),
            (observedAt: start.addingTimeInterval(5), epoch: 1_700_000_000),
            (observedAt: start.addingTimeInterval(6), epoch: 900)
        ])

        XCTAssertEqual(events, [
            OmiDiagnosticsPayload.PendantRebootEvent(
                observedAt: start.addingTimeInterval(3),
                epochBefore: 1_100,
                epochAfter: 700
            ),
            OmiDiagnosticsPayload.PendantRebootEvent(
                observedAt: start.addingTimeInterval(6),
                epochBefore: 1_700_000_000,
                epochAfter: 900
            )
        ])
    }

    func testExportSummaryIncludesLossRecoverabilityAdditions() {
        let start = Date(timeIntervalSince1970: 1_700)
        let payload = OmiDiagnosticsPayload(
            reconnectEvents: [
                OmiDiagnosticsPayload.ReconnectEvent(
                    timestamp: start,
                    reason: "link lost",
                    appStateAtDrop: "locked",
                    timeToReconnect: 5
                )
            ],
            decodeCounters: OmiDiagnosticsPayload.DecodeCounters(ok: 9, errors: 1),
            gapTallies: OmiDiagnosticsPayload.GapTallies(
                connectedSilentGapCount: 1,
                connectedSilentGapSeconds: 18,
                connectedSilentForegroundSeconds: 5,
                connectedSilentBackgroundSeconds: 6,
                connectedSilentLockedSeconds: 7
            ),
            subscribeLatencySamples: [
                OmiDiagnosticsPayload.SubscribeLatencySample(
                    timestamp: start,
                    latencySeconds: 3,
                    appState: "foreground"
                )
            ],
            storageBacklogSamples: [
                OmiDiagnosticsPayload.StorageBacklogSample(
                    timestamp: start,
                    usedBytes: 100,
                    rawHex: "6400000001000000",
                    fileCountUnconfirmed: 1
                ),
                OmiDiagnosticsPayload.StorageBacklogSample(
                    timestamp: start.addingTimeInterval(100),
                    usedBytes: 200,
                    rawHex: "c800000002000000",
                    fileCountUnconfirmed: 2
                )
            ],
            pendantRebootEvents: [
                OmiDiagnosticsPayload.PendantRebootEvent(
                    observedAt: start.addingTimeInterval(20),
                    epochBefore: 2_000,
                    epochAfter: 1_000
                )
            ],
            mtuAtConnect: 182,
            mtuAtSubscribeConfirm: 182,
            connectToFirstAudioSeconds: 1.5
        )

        let report = OmiDiagnosticsLogic.exportSummary(payload: payload, asOf: start.addingTimeInterval(200))

        XCTAssertTrue(report.contains("unrecoverable connect-to-subscribe: 3.00s total not on SD / unrecoverable"), report)
        XCTAssertTrue(report.contains("connected-without-audio buckets: foreground 5s, background 6s, locked 7s"), report)
        XCTAssertTrue(report.contains("disconnect window:"), report)
        XCTAssertTrue(report.contains("voiced-seconds received live: 0.18s voiced"), report)
        XCTAssertTrue(report.contains("recovery note: SD fills disconnect windows with voiced-only audio"), report)
        XCTAssertTrue(report.contains("silence note: connected-without-audio may be VAD silence"), report)
        XCTAssertTrue(report.contains("storage backlog: 100->200 bytes, growth 100, time-to-full projection"), report)
        XCTAssertTrue(report.contains("files 2 (layout-unconfirmed)"), report)
        XCTAssertTrue(report.contains("supporting readings: raw millivolts are not exposed over BLE on 3.0.19"), report)
        XCTAssertTrue(report.contains("supporting readings: reboot count 1"), report)
        XCTAssertTrue(report.contains("supporting readings: mtu connect 182, mtu subscribe-confirm 182, connect-to-first-audio 1.50s"), report)
    }

    func testExportSummaryAnnotatesReconnectCountWhenRingIsFull() {
        let start = Date(timeIntervalSince1970: 1_750)
        let fullEvents = (0..<OmiEventRing.capacity).map { index in
            OmiDiagnosticsPayload.ReconnectEvent(
                timestamp: start.addingTimeInterval(TimeInterval(index)),
                reason: "link lost",
                appStateAtDrop: "foreground",
                timeToReconnect: 1
            )
        }
        let fullReport = OmiDiagnosticsLogic.exportSummary(
            payload: OmiDiagnosticsPayload(reconnectEvents: fullEvents),
            asOf: start.addingTimeInterval(100)
        )

        XCTAssertTrue(
            fullReport.contains("reconnects: 50 (showing most recent 50 retained — see disconnect gaps for full count)\n"),
            fullReport
        )

        let belowCapacityReport = OmiDiagnosticsLogic.exportSummary(
            payload: OmiDiagnosticsPayload(reconnectEvents: Array(fullEvents.dropLast())),
            asOf: start.addingTimeInterval(100)
        )
        XCTAssertTrue(belowCapacityReport.contains("reconnects: 49\n"), belowCapacityReport)
        XCTAssertFalse(belowCapacityReport.contains("showing most recent"), belowCapacityReport)
    }

    func testExportSummaryAnnotatesSubscribeLatencySampleDenominator() {
        let start = Date(timeIntervalSince1970: 1_760)
        let payload = OmiDiagnosticsPayload(
            reconnectEvents: [
                OmiDiagnosticsPayload.ReconnectEvent(
                    timestamp: start,
                    reason: "link lost",
                    appStateAtDrop: "foreground",
                    timeToReconnect: 1
                ),
                OmiDiagnosticsPayload.ReconnectEvent(
                    timestamp: start.addingTimeInterval(10),
                    reason: "link lost",
                    appStateAtDrop: "locked",
                    timeToReconnect: 2
                )
            ],
            subscribeLatencySamples: [
                OmiDiagnosticsPayload.SubscribeLatencySample(
                    timestamp: start,
                    latencySeconds: 1.25,
                    appState: "foreground"
                ),
                OmiDiagnosticsPayload.SubscribeLatencySample(
                    timestamp: start.addingTimeInterval(10),
                    latencySeconds: 2.5,
                    appState: "locked"
                )
            ]
        )

        let report = OmiDiagnosticsLogic.exportSummary(payload: payload, asOf: start.addingTimeInterval(20))

        XCTAssertTrue(
            report.contains("unrecoverable connect-to-subscribe: 3.75s total not on SD / unrecoverable (foreground 1.25s, background 0.00s, locked 2.50s, 2 samples across 2 reconnects — unconfirmed reconnects not measured (foreground floor))\n"),
            report
        )
    }

    func testExportSummaryAnnotatesConnectedSilentBucketsQualifier() {
        let start = Date(timeIntervalSince1970: 1_770)
        let payload = OmiDiagnosticsPayload(
            gapTallies: OmiDiagnosticsPayload.GapTallies(
                connectedSilentForegroundSeconds: 5,
                connectedSilentBackgroundSeconds: 6,
                connectedSilentLockedSeconds: 7
            )
        )

        let report = OmiDiagnosticsLogic.exportSummary(payload: payload, asOf: start)

        XCTAssertTrue(
            report.contains("connected-without-audio buckets: foreground 5s, background 6s, locked 7s (foreground-sampled; background under-counted)\n"),
            report
        )
    }

    func testExportSummaryReportsStorageUnavailableWhenNeverRead() {
        let report = OmiDiagnosticsLogic.exportSummary(payload: OmiDiagnosticsPayload(), asOf: Date(timeIntervalSince1970: 1_800))

        XCTAssertTrue(report.contains("storage backlog: unavailable (characteristic never read)"), report)
        XCTAssertTrue(report.contains("unrecoverable connect-to-subscribe: unavailable (no subscribe-confirm samples)"), report)
    }

    private static func report(
        pendantBatteryTrend: [OmiDiagnosticsPayload.PendantBatterySample] = [],
        phoneSamples: [OmiDiagnosticsPayload.PhoneSample] = [],
        asOf date: Date
    ) -> String {
        let payload = OmiDiagnosticsPayload(
            pendantBatteryTrend: pendantBatteryTrend,
            phoneSamples: phoneSamples
        )
        return OmiDiagnosticsLogic.exportSummary(payload: payload, asOf: date)
    }

    private static func phoneSample(
        level: Double?,
        state: String?,
        at date: Date
    ) -> OmiDiagnosticsPayload.PhoneSample {
        OmiDiagnosticsPayload.PhoneSample(
            timestamp: date,
            batteryLevel: level,
            thermalState: "nominal",
            batteryState: state
        )
    }
}
