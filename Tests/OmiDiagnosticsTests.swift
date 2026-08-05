// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiDiagnosticsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testPersistReloadRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_000)
        let clock = MockObserverClock(now: start)
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(clock: clock, fileURL: fileURL)

        diagnostics.recordConnected()
        diagnostics.noteDecodedSamples(at: start.addingTimeInterval(1))
        diagnostics.updateDecodeCounters(
            ok: 8,
            errors: 2,
            gaps: 1,
            outOfOrder: 3,
            malformed: 4,
            droppedSamples: 5,
            failedOpens: 6
        )
        diagnostics.recordBattery(level: 87, at: start.addingTimeInterval(2))
        diagnostics.recordSignal(level: -62, at: start.addingTimeInterval(3))
        let reconnectIdentity = diagnostics.recordDisconnected(event: OmiSourceEvent(
            timestamp: start.addingTimeInterval(20),
            reason: "link lost",
            appStateAtDrop: "foreground",
            timeToReconnect: nil
        ))
        diagnostics.recordReconnect(identity: reconnectIdentity, latency: 4)
        clock.advance(by: 24)
        diagnostics.recordConnected()
        diagnostics.recordPhoneSample()

        let reloaded = OmiDiagnostics(clock: MockObserverClock(now: start.addingTimeInterval(30)), fileURL: fileURL)
        let payload = reloaded.payload

        XCTAssertEqual(payload.version, OmiDiagnosticsPayload.currentVersion)
        XCTAssertEqual(payload.firstObservedAt, start)
        XCTAssertEqual(payload.uptime.accumulatedConnectedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(payload.uptime.connectedSince, start.addingTimeInterval(24))
        XCTAssertEqual(payload.reconnectEvents.count, 1)
        XCTAssertEqual(payload.reconnectEvents.first?.reason, "link lost")
        XCTAssertEqual(payload.reconnectEvents.first?.timeToReconnect, 4)
        XCTAssertEqual(payload.decodeCounters, OmiDiagnosticsPayload.DecodeCounters(
            ok: 8,
            errors: 2,
            gaps: 1,
            outOfOrder: 3,
            droppedSamples: 5,
            failedOpens: 6,
            malformed: 4
        ))
        XCTAssertEqual(payload.pendantBatteryTrend, [
            OmiDiagnosticsPayload.PendantBatterySample(timestamp: start.addingTimeInterval(2), level: 87)
        ])
        XCTAssertEqual(payload.pendantSignalTrend, [
            OmiDiagnosticsPayload.PendantSignalSample(timestamp: start.addingTimeInterval(3), level: -62)
        ])
        XCTAssertEqual(payload.phoneSamples.count, 1)
        XCTAssertEqual(payload.gapTallies.disconnectGapCount, 1)
        XCTAssertEqual(payload.gapTallies.disconnectGapSeconds, 4, accuracy: 0.001)
        XCTAssertNil(payload.openDisconnectStartedAt)
        XCTAssertEqual(payload.lastDecodedSampleAt, start.addingTimeInterval(1))
    }

    @MainActor
    func testLoadsOldShapePayloadWithoutSignalTrend() throws {
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let oldShapeJSON = """
        {
          "version": 1,
          "firstObservedAt": "2024-04-20T12:00:00Z",
          "uptime": {
            "connectedSince": "2024-04-20T12:40:00Z",
            "accumulatedConnectedSeconds": 1800
          },
          "reconnectEvents": [
            {
              "timestamp": "2024-04-20T12:10:00Z",
              "reason": "link lost",
              "appStateAtDrop": "foreground",
              "timeToReconnect": 4.5
            }
          ],
          "decodeCounters": {
            "ok": 42,
            "errors": 2,
            "gaps": 3,
            "outOfOrder": 1
          },
          "pendantBatteryTrend": [
            {
              "timestamp": "2024-04-20T12:05:00Z",
              "level": 87
            }
          ],
          "phoneSamples": [
            {
              "timestamp": "2024-04-20T12:06:00Z",
              "batteryLevel": 0.75,
              "thermalState": "nominal"
            }
          ],
          "gapTallies": {
            "disconnectGapCount": 1,
            "disconnectGapSeconds": 4.5,
            "connectedSilentGapCount": 2,
            "connectedSilentGapSeconds": 90
          },
          "lastDecodedSampleAt": "2024-04-20T12:08:00Z",
          "openDisconnectStartedAt": null,
          "openConnectedSilentStartedAt": "2024-04-20T12:41:00Z"
        }
        """
        try Data(oldShapeJSON.utf8).write(to: fileURL)

        let diagnostics = OmiDiagnostics(clock: MockObserverClock(), fileURL: fileURL)
        let payload = diagnostics.payload

        XCTAssertEqual(payload.version, OmiDiagnosticsPayload.currentVersion)
        XCTAssertEqual(payload.firstObservedAt, Self.date("2024-04-20T12:00:00Z"))
        XCTAssertEqual(payload.uptime.connectedSince, Self.date("2024-04-20T12:40:00Z"))
        XCTAssertEqual(payload.uptime.accumulatedConnectedSeconds, 1800, accuracy: 0.001)
        XCTAssertEqual(payload.reconnectEvents, [
            OmiDiagnosticsPayload.ReconnectEvent(
                timestamp: Self.date("2024-04-20T12:10:00Z"),
                reason: "link lost",
                appStateAtDrop: "foreground",
                timeToReconnect: 4.5
            )
        ])
        XCTAssertEqual(payload.decodeCounters, OmiDiagnosticsPayload.DecodeCounters(ok: 42, errors: 2, gaps: 3, outOfOrder: 1))
        XCTAssertEqual(payload.pendantBatteryTrend, [
            OmiDiagnosticsPayload.PendantBatterySample(timestamp: Self.date("2024-04-20T12:05:00Z"), level: 87)
        ])
        XCTAssertNil(payload.pendantSignalTrend)
        XCTAssertEqual(payload.phoneSamples, [
            OmiDiagnosticsPayload.PhoneSample(
                timestamp: Self.date("2024-04-20T12:06:00Z"),
                batteryLevel: 0.75,
                thermalState: "nominal"
            )
        ])
        XCTAssertEqual(payload.gapTallies, OmiDiagnosticsPayload.GapTallies(
            disconnectGapCount: 1,
            disconnectGapSeconds: 4.5,
            connectedSilentGapCount: 2,
            connectedSilentGapSeconds: 90
        ))
        XCTAssertEqual(payload.lastDecodedSampleAt, Self.date("2024-04-20T12:08:00Z"))
        XCTAssertNil(payload.openDisconnectStartedAt)
        XCTAssertEqual(payload.openConnectedSilentStartedAt, Self.date("2024-04-20T12:41:00Z"))
    }

    @MainActor
    func testLoadsV2PayloadWithDecodeCountersDefaultingV3Fields() throws {
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let v2JSON = """
        {
          "version": 2,
          "firstObservedAt": "2024-05-21T08:00:00Z",
          "uptime": {
            "connectedSince": "2024-05-21T08:45:00Z",
            "accumulatedConnectedSeconds": 2700
          },
          "reconnectEvents": [
            {
              "timestamp": "2024-05-21T08:10:00Z",
              "reason": "link lost",
              "appStateAtDrop": "foreground",
              "timeToReconnect": 3.25
            }
          ],
          "decodeCounters": {
            "ok": 52,
            "errors": 3,
            "gaps": 4,
            "outOfOrder": 2
          },
          "pendantBatteryTrend": [
            {
              "timestamp": "2024-05-21T08:05:00Z",
              "level": 81,
              "rawByte": 81
            }
          ],
          "pendantSignalTrend": [
            {
              "timestamp": "2024-05-21T08:06:00Z",
              "level": -64
            }
          ],
          "phoneSamples": [
            {
              "timestamp": "2024-05-21T08:07:00Z",
              "batteryLevel": 0.66,
              "thermalState": "nominal",
              "batteryState": "unplugged"
            }
          ],
          "gapTallies": {
            "disconnectGapCount": 1,
            "disconnectGapSeconds": 3.25,
            "connectedSilentGapCount": 2,
            "connectedSilentGapSeconds": 120,
            "connectedSilentForegroundSeconds": 60,
            "connectedSilentBackgroundSeconds": 45,
            "connectedSilentLockedSeconds": 15
          },
          "lastDecodedSampleAt": "2024-05-21T08:08:00Z",
          "openDisconnectStartedAt": null,
          "openConnectedSilentStartedAt": "2024-05-21T08:46:00Z",
          "subscribeLatencySamples": [
            {
              "timestamp": "2024-05-21T08:09:00Z",
              "latencySeconds": 1.5,
              "appState": "foreground"
            }
          ],
          "storageBacklogSamples": [
            {
              "timestamp": "2024-05-21T08:11:00Z",
              "usedBytes": 1024,
              "rawHex": "00000400",
              "fileCountUnconfirmed": 2
            }
          ],
          "pendantRebootEvents": [
            {
              "observedAt": "2024-05-21T08:12:00Z",
              "epochBefore": 2000,
              "epochAfter": 100
            }
          ],
          "mtuAtConnect": 185,
          "mtuAtSubscribeConfirm": 185,
          "connectToFirstAudioSeconds": 2.75
        }
        """
        try Data(v2JSON.utf8).write(to: fileURL)

        let diagnostics = OmiDiagnostics(clock: MockObserverClock(), fileURL: fileURL)
        let payload = diagnostics.payload

        XCTAssertEqual(payload.version, OmiDiagnosticsPayload.currentVersion)
        XCTAssertEqual(payload.firstObservedAt, Self.date("2024-05-21T08:00:00Z"))
        XCTAssertEqual(payload.decodeCounters.ok, 52)
        XCTAssertEqual(payload.decodeCounters.errors, 3)
        XCTAssertEqual(payload.decodeCounters.gaps, 4)
        XCTAssertEqual(payload.decodeCounters.outOfOrder, 2)
        XCTAssertEqual(payload.decodeCounters.malformed, 0)
        XCTAssertEqual(payload.decodeCounters.droppedSamples, 0)
        XCTAssertEqual(payload.decodeCounters.failedOpens, 0)
        XCTAssertEqual(payload.pendantBatteryTrend.count, 1)
        XCTAssertEqual(payload.pendantSignalTrend?.first?.level, -64)
        XCTAssertEqual(payload.phoneSamples.first?.batteryState, "unplugged")
        XCTAssertEqual(payload.subscribeLatencySamples?.first?.latencySeconds, 1.5)
        XCTAssertEqual(payload.storageBacklogSamples?.first?.usedBytes, 1024)
        XCTAssertEqual(payload.pendantRebootEvents?.first?.epochAfter, 100)
        XCTAssertEqual(payload.mtuAtConnect, 185)
        XCTAssertEqual(payload.mtuAtSubscribeConfirm, 185)
        XCTAssertEqual(payload.connectToFirstAudioSeconds, 2.75)
    }

    @MainActor
    func testNoteDecodedSamplesDoesNotPersistPerFrame() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_100)
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(clock: MockObserverClock(now: start), fileURL: fileURL)

        diagnostics.recordConnected()
        let before = try Data(contentsOf: fileURL)
        diagnostics.noteDecodedSamples(at: start.addingTimeInterval(1))
        let after = try Data(contentsOf: fileURL)

        XCTAssertEqual(before, after)
        XCTAssertEqual(diagnostics.payload.lastDecodedSampleAt, start.addingTimeInterval(1))
    }

    @MainActor
    func testDecodeCountersAccumulateAcrossResetAndPersist() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_150)
        let clock = MockObserverClock(now: start)
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(clock: clock, fileURL: fileURL)

        diagnostics.updateDecodeCounters(ok: 2, errors: 1, gaps: 1, outOfOrder: 0, malformed: 1, droppedSamples: 2, failedOpens: 0)
        diagnostics.updateDecodeCounters(ok: 5, errors: 1, gaps: 2, outOfOrder: 1, malformed: 1, droppedSamples: 5, failedOpens: 1)
        diagnostics.updateDecodeCounters(ok: 9, errors: 2, gaps: 4, outOfOrder: 3, malformed: 3, droppedSamples: 8, failedOpens: 2)
        diagnostics.updateDecodeCounters(ok: 3, errors: 0, gaps: 1, outOfOrder: 2, malformed: 1, droppedSamples: 1, failedOpens: 1)

        let expected = OmiDiagnosticsPayload.DecodeCounters(
            ok: 12,
            errors: 2,
            gaps: 5,
            outOfOrder: 5,
            droppedSamples: 9,
            failedOpens: 3,
            malformed: 4
        )
        XCTAssertEqual(diagnostics.payload.decodeCounters, expected)

        diagnostics.recordPhoneSample()
        let reloaded = OmiDiagnostics(clock: MockObserverClock(now: start), fileURL: fileURL)
        XCTAssertEqual(reloaded.payload.decodeCounters, expected)

        let exportURL = try XCTUnwrap(diagnostics.exportFileURL())
        let report = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(report.contains("decode frames: 12 ok, 2 errors"), report)
        XCTAssertTrue(report.contains("audio gaps: 5"), report)
        XCTAssertTrue(report.contains("out of order frames: 5"), report)
        XCTAssertTrue(report.contains("malformed audio packets: 4"), report)
        XCTAssertTrue(report.contains("dropped audio samples: 9"), report)
        XCTAssertTrue(report.contains("audio file open failures: 3"), report)
    }

    @MainActor
    func testCoalescingFlushesOneWriteForSynchronousRecords() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_175)
        let sink = CountingOmiDiagnosticsPersistenceSink()
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(
            clock: MockObserverClock(now: start),
            fileURL: fileURL,
            persistenceSink: sink
        )

        diagnostics.beginCoalescing()
        diagnostics.recordConnected()
        diagnostics.recordDecodeCounters(ok: 1, errors: 2, gaps: 3, outOfOrder: 4, malformed: 5, droppedSamples: 6, failedOpens: 7)
        diagnostics.recordBattery(level: 87, at: start, rawByte: 87)
        diagnostics.recordSignal(level: -60, at: start)
        diagnostics.appendSubscribeLatency(timestamp: start, latencySeconds: 1.25, appState: "foreground")
        diagnostics.appendStorageBacklogSample(timestamp: start, usedBytes: 100, rawHex: "64000000", fileCountUnconfirmed: 1)
        diagnostics.appendPendantRebootEvent(observedAt: start, epochBefore: 2_000, epochAfter: 1_000)

        XCTAssertEqual(sink.writeCount, 1)
        diagnostics.endCoalescing()
        XCTAssertEqual(sink.writeCount, 2)
    }

    @MainActor
    func testPersistOutsideCoalescingWritesImmediately() throws {
        let sink = CountingOmiDiagnosticsPersistenceSink()
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(
            clock: MockObserverClock(),
            fileURL: fileURL,
            persistenceSink: sink
        )

        diagnostics.recordBattery(level: 88, at: Date(timeIntervalSince1970: 1_713_624_176))

        XCTAssertEqual(sink.writeCount, 2)
    }

    @MainActor
    func testSeriesCapsRetainMostRecentSamples() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_180)
        let clock = MockObserverClock(now: start)
        let sink = CountingOmiDiagnosticsPersistenceSink()
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(clock: clock, fileURL: fileURL, persistenceSink: sink)
        let minuteLimit = OmiDiagnosticsLogic.retainedMinuteSeriesSampleCount
        let eventLimit = OmiDiagnosticsLogic.retainedEventSeriesCount

        diagnostics.beginCoalescing()
        for index in 0..<(minuteLimit + 5) {
            let date = start.addingTimeInterval(TimeInterval(index * 60))
            diagnostics.recordBattery(level: index % 100, at: date, rawByte: UInt8(index % 100))
            diagnostics.recordSignal(level: -80 + (index % 40), at: date)
            diagnostics.appendStorageBacklogSample(
                timestamp: date,
                usedBytes: UInt32(index),
                rawHex: "00000000",
                fileCountUnconfirmed: UInt32(index % 10)
            )
            diagnostics.recordPhoneSample()
            clock.advance(by: 60)
        }
        for index in 0..<(eventLimit + 5) {
            let date = start.addingTimeInterval(TimeInterval(index))
            diagnostics.appendSubscribeLatency(
                timestamp: date,
                latencySeconds: TimeInterval(index),
                appState: "foreground"
            )
            diagnostics.appendPendantRebootEvent(
                observedAt: date,
                epochBefore: UInt32(index + 1_000),
                epochAfter: UInt32(index)
            )
        }
        diagnostics.endCoalescing()

        XCTAssertEqual(diagnostics.payload.pendantBatteryTrend.count, minuteLimit)
        XCTAssertEqual(diagnostics.payload.pendantSignalTrend?.count, minuteLimit)
        XCTAssertEqual(diagnostics.payload.storageBacklogSamples?.count, minuteLimit)
        XCTAssertEqual(diagnostics.payload.phoneSamples.count, minuteLimit)
        XCTAssertEqual(diagnostics.payload.subscribeLatencySamples?.count, eventLimit)
        XCTAssertEqual(diagnostics.payload.pendantRebootEvents?.count, eventLimit)
        XCTAssertEqual(diagnostics.payload.pendantBatteryTrend.first?.timestamp, start.addingTimeInterval(5 * 60))
        XCTAssertEqual(diagnostics.payload.storageBacklogSamples?.first?.usedBytes, 5)
        XCTAssertEqual(diagnostics.payload.subscribeLatencySamples?.first?.latencySeconds, 5)
        XCTAssertEqual(sink.writeCount, 2)
    }

    @MainActor
    func testLoadsOldShapePhoneSamplesWithoutBatteryState() throws {
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let oldShapeJSON = """
        {
          "version": 1,
          "firstObservedAt": "2024-04-20T12:00:00Z",
          "uptime": {
            "connectedSince": null,
            "accumulatedConnectedSeconds": 1800
          },
          "reconnectEvents": [],
          "decodeCounters": {
            "ok": 42,
            "errors": 2,
            "gaps": 3,
            "outOfOrder": 1
          },
          "pendantBatteryTrend": [],
          "phoneSamples": [
            {
              "timestamp": "2024-04-20T12:06:00Z",
              "batteryLevel": 0.75,
              "thermalState": "nominal"
            },
            {
              "timestamp": "2024-04-20T12:07:00Z",
              "batteryLevel": 0.65,
              "thermalState": "fair"
            }
          ],
          "gapTallies": {
            "disconnectGapCount": 0,
            "disconnectGapSeconds": 0,
            "connectedSilentGapCount": 0,
            "connectedSilentGapSeconds": 0
          },
          "lastDecodedSampleAt": null,
          "openDisconnectStartedAt": null,
          "openConnectedSilentStartedAt": null
        }
        """
        try Data(oldShapeJSON.utf8).write(to: fileURL)

        let diagnostics = OmiDiagnostics(clock: MockObserverClock(), fileURL: fileURL)
        let samples = diagnostics.payload.phoneSamples

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].batteryLevel, 0.75)
        XCTAssertEqual(samples[1].batteryLevel, 0.65)
        XCTAssertTrue(samples.allSatisfy { $0.batteryState == nil })
    }

    @MainActor
    func testLoadsV1ShapePayloadWithoutLossInstrumentationFields() throws {
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let oldShapeJSON = """
        {
          "version": 1,
          "firstObservedAt": "2024-04-20T12:00:00Z",
          "uptime": {
            "connectedSince": null,
            "accumulatedConnectedSeconds": 1800
          },
          "reconnectEvents": [],
          "decodeCounters": {
            "ok": 42,
            "errors": 2,
            "gaps": 3,
            "outOfOrder": 1
          },
          "pendantBatteryTrend": [
            {
              "timestamp": "2024-04-20T12:05:00Z",
              "level": 87
            }
          ],
          "phoneSamples": [],
          "gapTallies": {
            "disconnectGapCount": 0,
            "disconnectGapSeconds": 0,
            "connectedSilentGapCount": 1,
            "connectedSilentGapSeconds": 60
          },
          "lastDecodedSampleAt": null,
          "openDisconnectStartedAt": null,
          "openConnectedSilentStartedAt": null
        }
        """
        try Data(oldShapeJSON.utf8).write(to: fileURL)

        let diagnostics = OmiDiagnostics(clock: MockObserverClock(), fileURL: fileURL)
        let payload = diagnostics.payload

        XCTAssertEqual(payload.version, OmiDiagnosticsPayload.currentVersion)
        XCTAssertEqual(payload.pendantBatteryTrend.first?.rawByte, nil)
        XCTAssertNil(payload.gapTallies.connectedSilentForegroundSeconds)
        XCTAssertNil(payload.gapTallies.connectedSilentBackgroundSeconds)
        XCTAssertNil(payload.gapTallies.connectedSilentLockedSeconds)
        XCTAssertNil(payload.subscribeLatencySamples)
        XCTAssertNil(payload.storageBacklogSamples)
        XCTAssertNil(payload.pendantRebootEvents)
        XCTAssertNil(payload.mtuAtConnect)
        XCTAssertNil(payload.mtuAtSubscribeConfirm)
        XCTAssertNil(payload.connectToFirstAudioSeconds)

        let latency = OmiDiagnosticsLogic.subscribeLatencyBreakdown(payload.subscribeLatencySamples ?? [])
        XCTAssertEqual(latency.sampleCount, 0)
        XCTAssertEqual(latency.totalSeconds, 0)

        let attributed = OmiDiagnosticsLogic.addingSilentAttribution(
            to: payload.gapTallies,
            elapsed: 5,
            appState: "locked"
        )
        XCTAssertEqual(attributed.connectedSilentLockedSeconds, 5)
    }

    @MainActor
    func testExportFileContainsOwnerSummary() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_200)
        let clock = MockObserverClock(now: start)
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(clock: clock, fileURL: fileURL)

        diagnostics.recordConnected()
        diagnostics.updateDecodeCounters(ok: 9, errors: 1, gaps: 2, outOfOrder: 0, malformed: 3, droppedSamples: 4, failedOpens: 5)
        diagnostics.recordBattery(level: 92, at: start)
        diagnostics.recordSignal(level: -58, at: start.addingTimeInterval(1))
        let reconnectIdentity = diagnostics.recordDisconnected(event: OmiSourceEvent(
            timestamp: start.addingTimeInterval(10),
            reason: "link lost",
            appStateAtDrop: "foreground",
            timeToReconnect: nil
        ))
        diagnostics.recordReconnect(identity: reconnectIdentity, latency: 5)
        clock.advance(by: 15)
        diagnostics.recordConnected()
        diagnostics.recordPhoneSample()

        let exportURL = try XCTUnwrap(diagnostics.exportFileURL())
        let report = try String(contentsOf: exportURL, encoding: .utf8)

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
            "malformed audio packets:",
            "dropped audio samples:",
            "audio file open failures:",
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

    @MainActor
    func testProcessAnchorPreservesOldDeltasAndContinuesSequenceForSameProcess() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_300)
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let processA = UUID()
        let first = OmiDiagnostics(
            clock: MockObserverClock(now: start),
            fileURL: fileURL,
            processID: processA,
            processStartedAt: start
        )
        let firstIdentity = first.allocateEventIdentity()
        _ = first.recordDisconnected(event: OmiSourceEvent(
            timestamp: start,
            reason: "owner-only",
            appStateAtDrop: "foreground",
            timeToReconnect: nil,
            identity: firstIdentity
        ))

        let resumed = OmiDiagnostics(
            clock: MockObserverClock(now: start),
            fileURL: fileURL,
            processID: processA,
            processStartedAt: start
        )
        XCTAssertEqual(resumed.allocateEventIdentity().sequence, firstIdentity.sequence + 1)

        let processB = UUID()
        let restarted = OmiDiagnostics(
            clock: MockObserverClock(now: start.addingTimeInterval(1)),
            fileURL: fileURL,
            processID: processB,
            processStartedAt: start.addingTimeInterval(1)
        )
        XCTAssertEqual(restarted.payload.processID, processB)
        XCTAssertEqual(restarted.allocateEventIdentity().sequence, 0)
        XCTAssertEqual(restarted.payload.unhandedReconnectEvents?.first?.processID, processA)
    }

    @MainActor
    func testIdentityCompletionAndAcknowledgmentRetainNewerRevision() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_400)
        let diagnostics = OmiDiagnostics(
            clock: MockObserverClock(now: start),
            fileURL: self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        )
        let firstIdentity = diagnostics.allocateEventIdentity()
        let secondIdentity = diagnostics.allocateEventIdentity()
        _ = diagnostics.recordDisconnected(event: OmiSourceEvent(
            timestamp: start,
            reason: "first",
            appStateAtDrop: "foreground",
            timeToReconnect: nil,
            identity: firstIdentity
        ))
        _ = diagnostics.recordDisconnected(event: OmiSourceEvent(
            timestamp: start.addingTimeInterval(1),
            reason: "second",
            appStateAtDrop: "background",
            timeToReconnect: nil,
            identity: secondIdentity
        ))
        let frozen = diagnostics.frozenSegmentDeltas()
        diagnostics.recordReconnect(identity: firstIdentity, latency: 2)
        diagnostics.acknowledgeSegmentMetadata(tokens: frozen.tokens)

        let retained = diagnostics.payload.unhandedReconnectEvents ?? []
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.processID, firstIdentity.processID)
        XCTAssertEqual(retained.first?.sequence, firstIdentity.sequence)
        XCTAssertEqual(retained.first?.revision, 2)
        XCTAssertEqual(retained.first?.timeToReconnect, 2)
    }

    @MainActor
    func testSubscribePendingPersistsConnectedAtForZeroLatencyCompletion() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_500)
        let diagnostics = OmiDiagnostics(
            clock: MockObserverClock(now: start),
            fileURL: self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        )
        let identity = diagnostics.allocateEventIdentity()
        diagnostics.beginSubscribe(identity: identity, connectedAt: start, appState: "foreground")
        diagnostics.completeSubscribe(
            identity: identity,
            connectedAt: start,
            subscribedAt: start,
            latencySeconds: 0,
            appState: "foreground"
        )

        let sample = try XCTUnwrap(diagnostics.payload.unhandedSubscribeLatencySamples?.first)
        XCTAssertEqual(sample.connectedAt, start)
        XCTAssertEqual(sample.timestamp, start)
        XCTAssertEqual(sample.latencySeconds, 0)
        XCTAssertEqual(sample.revision, 2)
    }

    private static func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}

private final class CountingOmiDiagnosticsPersistenceSink: OmiDiagnosticsPersistenceSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var writeCount: Int {
        self.lock.withLock { self.count }
    }

    func write(_ data: Data) throws {
        self.lock.withLock {
            self.count += 1
        }
    }
}
