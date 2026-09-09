// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchSegmentPowerEnvelopeTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSegmentPowerEnvelopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        TransferURLProtocol.reset()
        if let dir = self.tempDirectory {
            try? FileManager.default.removeItem(at: dir)
            self.tempDirectory = nil
        }
        try super.tearDownWithError()
    }

    private func writeStagedSegment(
        stagingRoot: URL,
        manifest: WatchSegmentManifest,
        audioData: Data = Data("audio".utf8)
    ) throws {
        let segmentDirectory = stagingRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: segmentDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        if manifest.sensors.contains(.audio) {
            try audioData.write(to: segmentDirectory.appendingPathComponent("audio.m4a"), options: .atomic)
        }
    }

    private func dispatchAndExtractMeta(for watchManifest: WatchSegmentManifest) async throws -> [String: Any]? {
        TransferURLProtocol.reset()
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }

        let stagingRoot = self.tempDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: watchManifest)

        let resolver = TransferEndpointResolverStub(
            .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
        )
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("transfer-\(UUID().uuidString)", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: resolver
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.tempDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")),
            transferEnqueuer: harness.enqueuer,
            transferEngine: harness.engine
        )

        await drain.drain()
        try await harness.engine.start()

        try await transferTestWaitFor("dispatch body") {
            TransferURLProtocol.bodies.count == 1
        }

        let body = try XCTUnwrap(TransferURLProtocol.bodies.first)
        let envelope = try self.multipartEnvelope(in: body)
        return envelope["meta"] as? [String: Any]
    }

    func testFullPowerSamplePopulatesAllFourWireFields() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1776510000)
        let watchManifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: sampleDate,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil,
            deliveredAt: nil,
            batteryLevel: 0.85,
            batteryState: "unplugged",
            lowPowerMode: true,
            powerSampledAt: sampleDate
        )

        let rawMeta = try await self.dispatchAndExtractMeta(for: watchManifest)
        let meta = try XCTUnwrap(rawMeta)
        XCTAssertEqual(meta["battery_level"] as? Double, 0.85)
        XCTAssertEqual(meta["battery_state"] as? String, "unplugged")
        XCTAssertEqual(meta["low_power_mode"] as? Bool, true)
        XCTAssertEqual(meta["power_sampled_at"] as? String, ISO8601DateFormatter().string(from: sampleDate))
    }

    func testSentinelNilBatteryLevelOmittedOnWire() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1776510000)
        let watchManifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: sampleDate,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil,
            deliveredAt: nil,
            batteryLevel: nil,
            batteryState: "charging",
            lowPowerMode: false,
            powerSampledAt: sampleDate
        )

        let rawMeta = try await self.dispatchAndExtractMeta(for: watchManifest)
        let meta = try XCTUnwrap(rawMeta)
        XCTAssertNil(meta["battery_level"])
        XCTAssertEqual(meta["battery_state"] as? String, "charging")
        XCTAssertEqual(meta["low_power_mode"] as? Bool, false)
        XCTAssertEqual(meta["power_sampled_at"] as? String, ISO8601DateFormatter().string(from: sampleDate))
    }

    func testUnknownBatteryStateOmittedOnWire() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1776510000)
        let watchManifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: sampleDate,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil,
            deliveredAt: nil,
            batteryLevel: 0.70,
            batteryState: "unknown",
            lowPowerMode: false,
            powerSampledAt: sampleDate
        )

        let rawMeta = try await self.dispatchAndExtractMeta(for: watchManifest)
        let meta = try XCTUnwrap(rawMeta)
        XCTAssertNil(meta["battery_state"])
        XCTAssertEqual(meta["battery_level"] as? Double, 0.70)
        XCTAssertEqual(meta["low_power_mode"] as? Bool, false)
        XCTAssertEqual(meta["power_sampled_at"] as? String, ISO8601DateFormatter().string(from: sampleDate))
    }

    func testZeroBatteryLevelAndFalseLowPowerModeRetainedOnWire() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1776510000)
        let watchManifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: sampleDate,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil,
            deliveredAt: nil,
            batteryLevel: 0.0,
            batteryState: "unplugged",
            lowPowerMode: false,
            powerSampledAt: sampleDate
        )

        let rawMeta = try await self.dispatchAndExtractMeta(for: watchManifest)
        let meta = try XCTUnwrap(rawMeta)
        XCTAssertEqual(meta["battery_level"] as? Double, 0.0)
        XCTAssertEqual(meta["battery_state"] as? String, "unplugged")
        XCTAssertEqual(meta["low_power_mode"] as? Bool, false)
        XCTAssertEqual(meta["power_sampled_at"] as? String, ISO8601DateFormatter().string(from: sampleDate))
    }

    func testPowerSampledAtOnlyEmitsOnlyTimestamp() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1776510000)
        let watchManifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: sampleDate,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil,
            deliveredAt: nil,
            batteryLevel: nil,
            batteryState: nil,
            lowPowerMode: nil,
            powerSampledAt: sampleDate
        )

        let rawMeta = try await self.dispatchAndExtractMeta(for: watchManifest)
        let meta = try XCTUnwrap(rawMeta)
        XCTAssertNil(meta["battery_level"])
        XCTAssertNil(meta["battery_state"])
        XCTAssertNil(meta["low_power_mode"])
        XCTAssertEqual(meta["power_sampled_at"] as? String, ISO8601DateFormatter().string(from: sampleDate))
    }

    func testNoSampleOmitsAllFourKeys() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1776510000)
        let watchManifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: sampleDate,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil
        )

        let meta = try await self.dispatchAndExtractMeta(for: watchManifest)
        XCTAssertNil(meta?["battery_level"])
        XCTAssertNil(meta?["battery_state"])
        XCTAssertNil(meta?["low_power_mode"])
        XCTAssertNil(meta?["power_sampled_at"])
    }

    func testHop2MapperUnitOmissionRules() {
        let m1 = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil,
            deliveredAt: nil,
            batteryLevel: -1.0,
            batteryState: "unknown",
            lowPowerMode: true,
            powerSampledAt: Date(timeIntervalSince1970: 100)
        )
        let (level1, state1, lpm1, at1) = ObserverAudioTransferEnqueuer.mapWatchSegmentPowerForWire(watchManifest: m1)
        XCTAssertEqual(level1, -1.0)
        XCTAssertNil(state1)
        XCTAssertEqual(lpm1, true)
        XCTAssertNotNil(at1)

        let m2 = WatchSegmentManifest(
            id: UUID(),
            day: "20260420",
            segment: "120000_300",
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .captured,
            failureReason: nil,
            deliveredAt: nil,
            batteryLevel: 0.0,
            batteryState: "charging",
            lowPowerMode: false,
            powerSampledAt: Date(timeIntervalSince1970: 100)
        )
        let (level2, state2, lpm2, at2) = ObserverAudioTransferEnqueuer.mapWatchSegmentPowerForWire(watchManifest: m2)
        XCTAssertEqual(level2, 0.0)
        XCTAssertEqual(state2, "charging")
        XCTAssertEqual(lpm2, false)
        XCTAssertNotNil(at2)
    }
}
