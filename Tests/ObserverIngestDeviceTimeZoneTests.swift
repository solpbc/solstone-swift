// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class ObserverIngestDeviceTimeZoneTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverIngestDeviceTimeZoneTests-\(UUID().uuidString)", isDirectory: true)
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

    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    private func civilDate(day: String, hhmmss: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = Int(day.prefix(4))
        components.month = Int(day.dropFirst(4).prefix(2))
        components.day = Int(day.suffix(2))
        components.hour = Int(hhmmss.prefix(2))
        components.minute = Int(hhmmss.dropFirst(2).prefix(2))
        components.second = Int(hhmmss.suffix(2))
        return calendar.date(from: components)!
    }

    private func intValue(from value: Any?) -> Int? {
        if let intVal = value as? Int {
            return intVal
        }
        if let num = value as? NSNumber {
            return num.intValue
        }
        return nil
    }

    private func bodyData(_ payload: TransferBodyPayload) throws -> Data {
        switch payload {
        case .inMemory(let data):
            return data
        case .written(let url, _):
            return try Data(contentsOf: url)
        }
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

    private func dispatchAndExtractEnvelope(for watchManifest: WatchSegmentManifest) async throws -> [String: Any] {
        TransferURLProtocol.reset()
        TransferURLProtocol.handler = { request, body in
            (transferTestResponse(for: request, statusCode: 200), transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type")))
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
        return try self.multipartEnvelope(in: body)
    }

    func testPhoneEnvelopeStampsInjectedZone() async throws {
        struct Case {
            let zone: TimeZone
            let startedAt: Date
            let expectedTz: String?
            let expectedOffset: Int
            let expectedDay: String
            let expectedHHmmss: String
        }

        let cases: [Case] = [
            Case(
                zone: TimeZone(identifier: "America/Denver")!,
                startedAt: self.utcDate(year: 2026, month: 1, day: 15, hour: 19, minute: 0, second: 0),
                expectedTz: "America/Denver",
                expectedOffset: -25200,
                expectedDay: "20260115",
                expectedHHmmss: "120000"
            ),
            Case(
                zone: TimeZone(identifier: "America/Denver")!,
                startedAt: self.utcDate(year: 2026, month: 7, day: 15, hour: 18, minute: 0, second: 0),
                expectedTz: "America/Denver",
                expectedOffset: -21600,
                expectedDay: "20260715",
                expectedHHmmss: "120000"
            ),
            Case(
                zone: TimeZone(identifier: "Asia/Kolkata")!,
                startedAt: self.utcDate(year: 2026, month: 1, day: 15, hour: 6, minute: 30, second: 0),
                expectedTz: nil,
                expectedOffset: 19800,
                expectedDay: "20260115",
                expectedHHmmss: "120000"
            ),
        ]

        for (index, c) in cases.enumerated() {
            let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("spool-\(index)", isDirectory: true))
            let segmentID = UUID()
            var mobileManifest = MobileSegmentManifest(
                segmentID: segmentID,
                startedAt: c.startedAt,
                openedWithSources: [.audio],
                activeSourceSetVersion: 1
            )
            mobileManifest.durationS = 300

            let part = ObserverAudioTransferEnqueuer.audioPart()
            let transferManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
                itemID: segmentID,
                manifest: mobileManifest,
                now: c.startedAt,
                sources: [.audio],
                payloadParts: [part],
                timeZone: c.zone
            )

            let staged = try spool.stage(
                manifest: transferManifest,
                payloads: ["audio": Data("audio-data".utf8)]
            )
            let reloadedManifest = try spool.readManifest(in: staged.item.directoryURL)
            let item = TransferStoredItem(manifest: reloadedManifest, directoryURL: staged.item.directoryURL)
            let payload = try DefaultTransferBodyBuilder.build(item: item, spool: spool)
            let body = try self.bodyData(payload)
            let envelope = try self.multipartEnvelope(in: body)

            XCTAssertEqual(envelope["day"] as? String, c.expectedDay)
            let segment = try XCTUnwrap(envelope["segment"] as? String)
            XCTAssertTrue(segment.hasPrefix(c.expectedHHmmss))

            let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
            XCTAssertEqual(meta["tz"] as? String, c.expectedTz)
            XCTAssertEqual(self.intValue(from: meta["utc_offset_seconds"]), c.expectedOffset)
            if c.expectedTz == nil {
                XCTAssertNil(meta["tz"])
                XCTAssertNotNil(meta["utc_offset_seconds"])
            }
            XCTAssertEqual(meta["platform"] as? String, "ios")
            XCTAssertNotNil(meta["duration_s"])
            XCTAssertNotNil(meta["sources"])

            let startedAtStr = try XCTUnwrap(meta["started_at"] as? String)
            let parsedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: startedAtStr))
            XCTAssertEqual(parsedDate.timeIntervalSince(c.startedAt), 0, accuracy: 1)

            let dayFromEnvelope = try XCTUnwrap(envelope["day"] as? String)
            let segmentFromEnvelope = try XCTUnwrap(envelope["segment"] as? String)
            let hhmmssFromEnvelope = String(segmentFromEnvelope.prefix(6))
            let offsetFromEnvelope = try XCTUnwrap(self.intValue(from: meta["utc_offset_seconds"]))

            let civil = self.civilDate(day: dayFromEnvelope, hhmmss: hhmmssFromEnvelope)
            let reconstructedUTC = civil.addingTimeInterval(TimeInterval(-offsetFromEnvelope))
            XCTAssertEqual(reconstructedUTC.timeIntervalSince(c.startedAt), 0, accuracy: 1)
        }
    }

    func testStoredStampSurvivesRetryAndIsNotReplaced() async throws {
        let denverZone = TimeZone(identifier: "America/Denver")!
        let kolkataZone = TimeZone(identifier: "Asia/Kolkata")!
        let startedAt = self.utcDate(year: 2026, month: 1, day: 15, hour: 19, minute: 0, second: 0)

        let day = MobileSegmentUploader.dayString(for: startedAt, timeZone: denverZone)
        let segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 300, timeZone: denverZone)
        let stamp = SegmentTimeZoneStamp(timeZone: denverZone, startedAt: startedAt)

        let segmentID = UUID()
        var mobileManifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1,
            day: day,
            segment: segment,
            tz: stamp.tz,
            utcOffsetSeconds: stamp.utcOffsetSeconds
        )
        mobileManifest.durationS = 300

        let part = ObserverAudioTransferEnqueuer.audioPart()
        let transferManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: segmentID,
            manifest: mobileManifest,
            now: startedAt,
            sources: [.audio],
            payloadParts: [part],
            timeZone: kolkataZone
        )

        let ingest = try XCTUnwrap(transferManifest.observerIngest)
        XCTAssertEqual(ingest.day, "20260115")
        XCTAssertEqual(ingest.segment, "120000_300")
        XCTAssertEqual(ingest.tz, "America/Denver")
        XCTAssertEqual(ingest.utcOffsetSeconds, -25200)

        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("retry-spool", isDirectory: true))
        let staged = try spool.stage(
            manifest: transferManifest,
            payloads: ["audio": Data("audio-bytes".utf8)]
        )
        let reloadedManifest = try spool.readManifest(in: staged.item.directoryURL)
        let item = TransferStoredItem(manifest: reloadedManifest, directoryURL: staged.item.directoryURL)
        let payload = try DefaultTransferBodyBuilder.build(item: item, spool: spool)
        let body = try self.bodyData(payload)
        let envelope = try self.multipartEnvelope(in: body)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])

        XCTAssertEqual(meta["tz"] as? String, "America/Denver")
        XCTAssertEqual(self.intValue(from: meta["utc_offset_seconds"]), -25200)

        let segmentID3 = UUID()
        var mobileManifest3 = MobileSegmentManifest(
            segmentID: segmentID3,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1,
            day: day,
            segment: segment,
            tz: nil,
            utcOffsetSeconds: nil
        )
        mobileManifest3.durationS = 300

        let transferManifest3 = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: segmentID3,
            manifest: mobileManifest3,
            now: startedAt,
            sources: [.audio],
            payloadParts: [part],
            timeZone: kolkataZone
        )

        let ingest3 = try XCTUnwrap(transferManifest3.observerIngest)
        XCTAssertNil(ingest3.tz)
        XCTAssertNil(ingest3.utcOffsetSeconds)

        let spool3 = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("nil-spool", isDirectory: true))
        let staged3 = try spool3.stage(
            manifest: transferManifest3,
            payloads: ["audio": Data("audio-bytes".utf8)]
        )
        let reloaded3 = try spool3.readManifest(in: staged3.item.directoryURL)
        let item3 = TransferStoredItem(manifest: reloaded3, directoryURL: staged3.item.directoryURL)
        let payload3 = try DefaultTransferBodyBuilder.build(item: item3, spool: spool3)
        let body3 = try self.bodyData(payload3)
        let envelope3 = try self.multipartEnvelope(in: body3)
        let meta3 = try XCTUnwrap(envelope3["meta"] as? [String: Any])
        XCTAssertNil(meta3["tz"])
        XCTAssertNil(meta3["utc_offset_seconds"])
    }

    func testWatchEnvelopePassesWatchStamp() async throws {
        struct Case {
            let zone: TimeZone
            let startedAt: Date
            let expectedTz: String?
            let expectedOffset: Int
            let expectedDay: String
            let expectedHHmmss: String
        }

        let cases: [Case] = [
            Case(
                zone: TimeZone(identifier: "America/Denver")!,
                startedAt: self.utcDate(year: 2026, month: 1, day: 15, hour: 19, minute: 0, second: 0),
                expectedTz: "America/Denver",
                expectedOffset: -25200,
                expectedDay: "20260115",
                expectedHHmmss: "120000"
            ),
            Case(
                zone: TimeZone(identifier: "Asia/Kolkata")!,
                startedAt: self.utcDate(year: 2026, month: 1, day: 15, hour: 6, minute: 30, second: 0),
                expectedTz: nil,
                expectedOffset: 19800,
                expectedDay: "20260115",
                expectedHHmmss: "120000"
            ),
        ]

        for c in cases {
            let day = WatchCaptureStoragePaths.dayString(for: c.startedAt, timeZone: c.zone)
            let segment = WatchCaptureStoragePaths.segmentString(for: c.startedAt, durationSeconds: 300, timeZone: c.zone)
            let stamp = SegmentTimeZoneStamp(timeZone: c.zone, startedAt: c.startedAt)

            var watchManifest = WatchSegmentManifest(
                id: UUID(),
                day: day,
                segment: segment,
                startedAt: c.startedAt,
                duration: 300,
                sensors: [.audio],
                partial: false,
                lost: false,
                gap: false,
                fixCount: 0,
                state: .captured,
                failureReason: nil
            )
            watchManifest.tz = stamp.tz
            watchManifest.utcOffsetSeconds = stamp.utcOffsetSeconds

            let envelope = try await self.dispatchAndExtractEnvelope(for: watchManifest)
            XCTAssertEqual(envelope["day"] as? String, c.expectedDay)
            let segmentKey = try XCTUnwrap(envelope["segment"] as? String)
            XCTAssertTrue(segmentKey.hasPrefix(c.expectedHHmmss))

            let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
            XCTAssertEqual(meta["tz"] as? String, c.expectedTz)
            XCTAssertEqual(self.intValue(from: meta["utc_offset_seconds"]), c.expectedOffset)
            if c.expectedTz == nil {
                XCTAssertNil(meta["tz"])
                XCTAssertNotNil(meta["utc_offset_seconds"])
            }
            XCTAssertEqual(meta["platform"] as? String, "watchos")
            XCTAssertNotNil(meta["duration_s"])
            XCTAssertNotNil(meta["sources"])

            let startedAtStr = try XCTUnwrap(meta["started_at"] as? String)
            let parsedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: startedAtStr))
            XCTAssertEqual(parsedDate.timeIntervalSince(c.startedAt), 0, accuracy: 1)

            let dayFromEnvelope = try XCTUnwrap(envelope["day"] as? String)
            let segmentFromEnvelope = try XCTUnwrap(envelope["segment"] as? String)
            let hhmmssFromEnvelope = String(segmentFromEnvelope.prefix(6))
            let offsetFromEnvelope = try XCTUnwrap(self.intValue(from: meta["utc_offset_seconds"]))

            let civil = self.civilDate(day: dayFromEnvelope, hhmmss: hhmmssFromEnvelope)
            let reconstructedUTC = civil.addingTimeInterval(TimeInterval(-offsetFromEnvelope))
            XCTAssertEqual(reconstructedUTC.timeIntervalSince(c.startedAt), 0, accuracy: 1)
        }

        let sampleDate = self.utcDate(year: 2026, month: 1, day: 15, hour: 19, minute: 0, second: 0)
        let plainManifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260115",
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
        let envelope = try await self.dispatchAndExtractEnvelope(for: plainManifest)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
        XCTAssertNil(meta["tz"])
        XCTAssertNil(meta["utc_offset_seconds"])
    }
}
