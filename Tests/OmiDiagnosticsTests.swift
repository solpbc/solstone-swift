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
        diagnostics.updateDecodeCounters(ok: 8, errors: 2, gaps: 1, outOfOrder: 3)
        diagnostics.recordBattery(level: 87, at: start.addingTimeInterval(2))
        diagnostics.recordSignal(level: -62, at: start.addingTimeInterval(3))
        diagnostics.recordDisconnected(event: OmiSourceEvent(
            timestamp: start.addingTimeInterval(20),
            reason: "link lost",
            appStateAtDrop: "foreground",
            timeToReconnect: nil
        ))
        diagnostics.recordReconnect(latency: 4)
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
        XCTAssertEqual(payload.decodeCounters, OmiDiagnosticsPayload.DecodeCounters(ok: 8, errors: 2, gaps: 1, outOfOrder: 3))
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

        XCTAssertEqual(payload.version, 1)
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

        diagnostics.updateDecodeCounters(ok: 2, errors: 1, gaps: 1, outOfOrder: 0)
        diagnostics.updateDecodeCounters(ok: 5, errors: 1, gaps: 2, outOfOrder: 1)
        diagnostics.updateDecodeCounters(ok: 9, errors: 2, gaps: 4, outOfOrder: 3)
        diagnostics.updateDecodeCounters(ok: 3, errors: 0, gaps: 1, outOfOrder: 2)

        let expected = OmiDiagnosticsPayload.DecodeCounters(
            ok: 12,
            errors: 2,
            gaps: 5,
            outOfOrder: 5
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

        XCTAssertEqual(payload.version, 1)
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
        diagnostics.updateDecodeCounters(ok: 9, errors: 1, gaps: 2, outOfOrder: 0)
        diagnostics.recordBattery(level: 92, at: start)
        diagnostics.recordSignal(level: -58, at: start.addingTimeInterval(1))
        diagnostics.recordDisconnected(event: OmiSourceEvent(
            timestamp: start.addingTimeInterval(10),
            reason: "link lost",
            appStateAtDrop: "foreground",
            timeToReconnect: nil
        ))
        diagnostics.recordReconnect(latency: 5)
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

    private static func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
