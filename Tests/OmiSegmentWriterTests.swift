// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import XCTest

nonisolated final class OmiSegmentWriterTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiSegmentWriterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testRotationSuspendedThenWakeRotatesOnAppend() async throws {
        let clock = MockObserverClock()
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)

        writer.start()
        writer.append(self.samples(count: 3200))
        clock.advance(by: 299)
        writer.append(self.samples(count: 1600))
        XCTAssertEqual(uploader.pendingCount, 0)

        clock.advance(by: 1)
        XCTAssertEqual(uploader.pendingCount, 0)
        writer.append(self.samples(count: 1600))

        try await self.waitForPendingCount(1, uploader: uploader)
        var chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0])

        writer.stop()
        try await self.waitForPendingCount(2, uploader: uploader)
        chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0, 1])
        XCTAssertEqual(Set(chunks.map(\.sidecar.sessionID)).count, 1)
    }

    @MainActor
    func testFinalizeOpenChunkContinuesSessionWithNextChunkIndex() async throws {
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: MockObserverClock())

        writer.start()
        writer.append(self.samples(count: 3200))
        await writer.finalizeOpenChunk()

        try await self.waitForPendingCount(1, uploader: uploader)
        var chunks = try self.pendingChunks()
        let first = try XCTUnwrap(chunks.first)
        XCTAssertEqual(first.sidecar.chunkIndex, 0)
        XCTAssertNoThrow(try AVAudioFile(forReading: first.audioURL))

        writer.append(self.samples(count: 3200))
        await writer.finalizeOpenChunk()

        try await self.waitForPendingCount(2, uploader: uploader)
        chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0, 1])
        XCTAssertEqual(Set(chunks.map(\.sidecar.sessionID)).count, 1)
    }

    @MainActor
    func testFinalizeOpenChunkSkipsEmptyChunk() async throws {
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: MockObserverClock())

        writer.start()
        await writer.finalizeOpenChunk()

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertTrue(try self.files(withExtension: "m4a").isEmpty)
    }

    @MainActor
    func testFinalizeOpenChunkIsIdempotentWithoutIndexGaps() async throws {
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: MockObserverClock())

        writer.start()
        writer.append(self.samples(count: 3200))
        await writer.finalizeOpenChunk()
        await writer.finalizeOpenChunk()
        writer.append(self.samples(count: 3200))
        await writer.finalizeOpenChunk()

        try await self.waitForPendingCount(2, uploader: uploader)
        let chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0, 1])
        XCTAssertEqual(Set(chunks.map(\.sidecar.chunkIndex)).count, chunks.count)
    }

    @MainActor
    func testEmptyChunksAreSkippedAndRemoved() async throws {
        let clock = MockObserverClock()
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)
        var finalizedEvents: [FinalizedChunkEvent] = []
        writer.onChunkFinalized = { day, durationS, identity in
            finalizedEvents.append(FinalizedChunkEvent(day: day, durationS: durationS, identity: identity))
        }

        writer.start()
        writer.stop()

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertTrue(try self.files(withExtension: "m4a").isEmpty)
        XCTAssertTrue(finalizedEvents.isEmpty)

        writer.start()
        writer.append(self.samples(count: 1))
        writer.stop()

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertTrue(try self.files(withExtension: "m4a").isEmpty)
        XCTAssertTrue(finalizedEvents.isEmpty)

        writer.start()
        clock.advance(by: 300)
        writer.append(self.samples(count: 3200))
        writer.stop()

        try await self.waitForPendingCount(1, uploader: uploader)
        let chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [1])
        XCTAssertFalse(chunks.contains { $0.chunkID.hasSuffix("-0") })
        XCTAssertEqual(finalizedEvents.count, 1)
    }

    @MainActor
    func testChunkFinalizedHookFiresBeforeUploadDelivery() async throws {
        let start = Date(timeIntervalSince1970: 1_713_624_000)
        let clock = MockObserverClock(now: start)
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)
        var finalizedEvents: [FinalizedChunkEvent] = []
        writer.onChunkFinalized = { day, durationS, identity in
            finalizedEvents.append(FinalizedChunkEvent(day: day, durationS: durationS, identity: identity))
        }

        writer.start()
        writer.append(self.samples(count: 3200))
        clock.advance(by: 300)
        writer.append(self.samples(count: 1600))

        try await self.waitForPendingCount(1, uploader: uploader)
        let chunk = try XCTUnwrap(self.pendingChunks().first)
        XCTAssertEqual(finalizedEvents.count, 1)
        let event = try XCTUnwrap(finalizedEvents.first)
        XCTAssertEqual(event.day, self.dayString(for: start))
        XCTAssertEqual(event.durationS, 0.2, accuracy: 0.0001)
        XCTAssertEqual(event.identity, chunk.chunkID)
        XCTAssertEqual(chunk.sidecar.durationS, 0.2, accuracy: 0.0001)
        XCTAssertEqual(chunk.chunkID, "\(chunk.sidecar.sessionID.uuidString.lowercased())-0")
        XCTAssertEqual(event.durationS, chunk.sidecar.durationS, accuracy: 0.0001)
    }

    @MainActor
    func testSidecarShapeAfterRotation() async throws {
        let start = Date(timeIntervalSince1970: 1_713_624_000)
        let clock = MockObserverClock(now: start)
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)

        writer.start()
        writer.append(self.samples(count: 3200))
        clock.advance(by: 300)
        writer.append(self.samples(count: 1600))

        try await self.waitForPendingCount(1, uploader: uploader)
        var chunks = try self.pendingChunks()
        let first = try XCTUnwrap(chunks.first)
        XCTAssertEqual(first.sidecar.segment, self.segmentString(for: start, durationSeconds: first.sidecar.durationS))
        XCTAssertEqual(first.sidecar.day, self.dayString(for: start))
        XCTAssertEqual(first.sidecar.chunkIndex, 0)
        XCTAssertEqual(first.sidecar.startedAt.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(first.sidecar.durationS, 0.2, accuracy: 0.0001)
        XCTAssertEqual(first.sidecar.mode, .meeting)
        XCTAssertEqual(first.chunkID, "\(first.sidecar.sessionID.uuidString.lowercased())-0")
        XCTAssertGreaterThan(try self.byteCount(at: first.audioURL), 0)

        writer.stop()
        try await self.waitForPendingCount(2, uploader: uploader)
        chunks = try self.pendingChunks()
        let second = try XCTUnwrap(chunks.first { $0.sidecar.chunkIndex == 1 })
        XCTAssertEqual(second.sidecar.sessionID, first.sidecar.sessionID)
    }

    @MainActor
    func testPCM16BufferFraming() throws {
        let buffer = try XCTUnwrap(OmiSegmentWriter.makeBuffer([1, -2, 3, -4]))

        XCTAssertEqual(buffer.frameCapacity, 4)
        XCTAssertEqual(buffer.frameLength, 4)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertFalse(buffer.format.isInterleaved)
        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        XCTAssertEqual(channel[0], 1)
        XCTAssertEqual(channel[1], -2)
        XCTAssertEqual(channel[2], 3)
        XCTAssertEqual(channel[3], -4)
    }

    func testKeychainAccountIsolation() {
        XCTAssertEqual(ObserverKeychain.observerIngestKeyAccount, "solstone-swift-observer-ingest-key")
        XCTAssertEqual(ObserverKeychain.omiIngestKeyAccount, "solstone-swift-omi-ingest-key")
        XCTAssertNotEqual(ObserverKeychain.observerIngestKeyAccount, ObserverKeychain.omiIngestKeyAccount)
    }

    @MainActor
    func testSegmentStringUsesLocalTimeAndRoundedPositiveDuration() throws {
        let date = try self.fixedLocalDate(hour: 10, minute: 43, second: 55)

        let segments = [
            ObserverSegmentNaming.segmentString(for: date, durationSeconds: 300.0),
            ObserverSegmentNaming.segmentString(for: date, durationSeconds: 0.4),
            ObserverSegmentNaming.segmentString(for: date, durationSeconds: 47.6),
        ]

        XCTAssertEqual(segments[0], "104355_300")
        XCTAssertEqual(segments[1], "104355_1")
        XCTAssertEqual(segments[2], "104355_48")
        for segment in segments {
            XCTAssertTrue(segment.range(of: #"^\d{6}_\d+$"#, options: .regularExpression) != nil)
        }
    }

    @MainActor
    func testSessionSurvivesReconnectGapUnderRotationThreshold() async throws {
        let clock = MockObserverClock()
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)

        writer.start()
        writer.append(self.samples(count: 3200))
        clock.advance(by: 299)
        writer.append(self.samples(count: 3200))
        writer.stop()

        try await self.waitForPendingCount(1, uploader: uploader)
        let chunks = try self.pendingChunks()
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunk.sidecar.chunkIndex, 0)
        XCTAssertEqual(Set(chunks.map(\.sidecar.sessionID)).count, 1)
        XCTAssertEqual(chunk.sidecar.durationS, 0.4, accuracy: 0.0001)
    }

    @MainActor
    func testRestoreStartedWriterEnqueuesChunksWithoutEnable() async throws {
        let clock = MockObserverClock()
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)

        writer.start()
        writer.append(self.samples(count: 3200))
        clock.advance(by: 300)
        writer.append(self.samples(count: 1600))

        try await self.waitForPendingCount(1, uploader: uploader)
        let chunks = try self.pendingChunks()
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0])
    }

    @MainActor
    func testStartIsIdempotentAndPreservesSessionAcrossRetriggers() async throws {
        let clock = MockObserverClock()
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)

        writer.start()
        writer.start()
        writer.append(self.samples(count: 3200))
        clock.advance(by: 299)
        writer.start()
        writer.append(self.samples(count: 3200))
        writer.stop()

        try await self.waitForPendingCount(1, uploader: uploader)
        let chunks = try self.pendingChunks()
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0])
        XCTAssertEqual(Set(chunks.map(\.sidecar.sessionID)).count, 1)
        XCTAssertEqual(chunk.sidecar.durationS, 0.4, accuracy: 0.0001)
    }

    @MainActor
    func testEnableAfterRestoreStartAdoptsExistingSession() async throws {
        let clock = MockObserverClock()
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(uploader: uploader, clock: clock)

        writer.start()
        writer.append(self.samples(count: 3200))
        writer.start()
        clock.advance(by: 300)
        writer.append(self.samples(count: 1600))
        writer.stop()

        try await self.waitForPendingCount(2, uploader: uploader)
        let chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0, 1])
        XCTAssertEqual(Set(chunks.map(\.sidecar.sessionID)).count, 1)
        XCTAssertEqual(Set(chunks.map(\.sidecar.chunkIndex)).count, chunks.count)
    }
}

private struct FinalizedChunkEvent: Sendable {
    let day: String
    let durationS: TimeInterval
    let identity: String
}

@MainActor
private extension OmiSegmentWriterTests {
    struct PendingChunk {
        let chunkID: String
        let audioURL: URL
        let sidecar: ChunkSidecar
    }

    func makeUploader() -> ObserverUploader {
        ObserverUploader(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: .ephemeral,
            ensureRegistered: { "test-omi-key-abc" },
            isJournalConfigured: { true },
            localPortProvider: { nil },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
    }

    func samples(count: Int) -> [Int16] {
        (0..<count).map { Int16($0 % 128) }
    }

    func waitForPendingCount(
        _ count: Int,
        uploader: ObserverUploader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if uploader.pendingCount == count {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for pendingCount \(count)", file: file, line: line)
    }

    func pendingChunks() throws -> [PendingChunk] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try self.files(withExtension: "json")
            .filter { $0.deletingLastPathComponent().lastPathComponent == "pending" }
            .map { sidecarURL in
                let chunkID = sidecarURL.deletingPathExtension().lastPathComponent
                let sidecar = try decoder.decode(ChunkSidecar.self, from: Data(contentsOf: sidecarURL))
                let audioURL = sidecarURL.deletingLastPathComponent()
                    .appendingPathComponent("\(chunkID).m4a", isDirectory: false)
                return PendingChunk(chunkID: chunkID, audioURL: audioURL, sidecar: sidecar)
            }
            .sorted { $0.sidecar.chunkIndex < $1.sidecar.chunkIndex }
    }

    func files(withExtension pathExtension: String) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: self.tempDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            urls.append(url)
        }
        return urls
    }

    func byteCount(at url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    func segmentString(for date: Date, durationSeconds: Double) -> String {
        ObserverSegmentNaming.segmentString(for: date, durationSeconds: durationSeconds)
    }

    func dayString(for date: Date) -> String {
        ObserverSegmentNaming.dayString(for: date)
    }

    func fixedLocalDate(hour: Int, minute: Int, second: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: 2026,
            month: 4,
            day: 20,
            hour: hour,
            minute: minute,
            second: second
        )
        return try XCTUnwrap(calendar.date(from: components))
    }
}
