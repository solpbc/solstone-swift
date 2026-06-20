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
        XCTAssertEqual(payload.phoneSamples.count, 1)
        XCTAssertEqual(payload.gapTallies.disconnectGapCount, 1)
        XCTAssertEqual(payload.gapTallies.disconnectGapSeconds, 4, accuracy: 0.001)
        XCTAssertNil(payload.openDisconnectStartedAt)
        XCTAssertEqual(payload.lastDecodedSampleAt, start.addingTimeInterval(1))
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
    func testExportFileContainsOwnerSummary() throws {
        let start = Date(timeIntervalSince1970: 1_713_624_200)
        let clock = MockObserverClock(now: start)
        let fileURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json")
        let diagnostics = OmiDiagnostics(clock: clock, fileURL: fileURL)

        diagnostics.recordConnected()
        diagnostics.updateDecodeCounters(ok: 9, errors: 1, gaps: 2, outOfOrder: 0)
        diagnostics.recordBattery(level: 92, at: start)
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
