// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Dispatch
import Foundation
import os
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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)

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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: MockObserverClock())

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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: MockObserverClock())

        writer.start()
        await writer.finalizeOpenChunk()

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertTrue(try self.files(withExtension: "m4a").isEmpty)
    }

    @MainActor
    func testFinalizeOpenChunkIsIdempotentWithoutIndexGaps() async throws {
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: MockObserverClock())

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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)
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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)
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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)

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
        let samples: [Int16] = [1, -2, 3, -4]
        let buffer = try XCTUnwrap(OmiAudioChunkFormat.makeBuffer(samples[...]))

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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)

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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)

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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)

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
        let writer = OmiSegmentWriter(transferEnqueuer: uploader.transferEnqueuer, cacheRootURL: self.tempDirectory, clock: clock)

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

    @MainActor
    func testSingleAppendCrossingOneSampleBoundaryProducesDistinctChunks() async throws {
        let start = try self.fixedLocalDate(hour: 10, minute: 43, second: 55)
        let clock = MockObserverClock(now: start)
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(
            transferEnqueuer: uploader.transferEnqueuer,
            cacheRootURL: self.tempDirectory,
            clock: clock,
            sampleLimit: 16_000
        )

        writer.start()
        writer.append(self.samples(count: 32_000))
        try await self.waitForPendingCount(1, uploader: uploader)
        writer.stop()
        try await self.waitForPendingCount(2, uploader: uploader)

        let chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0, 1])
        XCTAssertEqual(Set(chunks.map(\.sidecar.sessionID)).count, 1)
        XCTAssertEqual(chunks.map(\.sidecar.durationS), [1, 1])
        XCTAssertEqual(chunks.map(\.sidecar.startedAt), [start, start.addingTimeInterval(1)])
        XCTAssertEqual(Set(chunks.map { "\($0.sidecar.day)/\($0.sidecar.segment)" }).count, 2)
    }

    @MainActor
    func testSingleAppendCrossingMultipleSampleBoundariesPreservesChronology() async throws {
        let start = try self.fixedLocalDate(hour: 10, minute: 43, second: 55)
        let clock = MockObserverClock(now: start)
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(
            transferEnqueuer: uploader.transferEnqueuer,
            cacheRootURL: self.tempDirectory,
            clock: clock,
            sampleLimit: 16_000
        )

        writer.start()
        writer.append(self.samples(count: 48_000))
        try await self.waitForPendingCount(2, uploader: uploader)
        writer.stop()
        try await self.waitForPendingCount(3, uploader: uploader)

        let chunks = try self.pendingChunks()
        XCTAssertEqual(chunks.map(\.sidecar.chunkIndex), [0, 1, 2])
        XCTAssertEqual(Set(chunks.map(\.sidecar.sessionID)).count, 1)
        XCTAssertEqual(chunks.map(\.sidecar.durationS), [1, 1, 1])
        XCTAssertEqual(
            chunks.map(\.sidecar.startedAt),
            [start, start.addingTimeInterval(1), start.addingTimeInterval(2)]
        )
        XCTAssertEqual(Set(chunks.map { "\($0.sidecar.day)/\($0.sidecar.segment)" }).count, 3)
    }

    @MainActor
    func testSampleBoundaryOpenFailureDropsRemainingPartitionsAndSignalsFaultOnce() async throws {
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(
            transferEnqueuer: uploader.transferEnqueuer,
            cacheRootURL: self.tempDirectory,
            clock: MockObserverClock(),
            sampleLimit: 1_600
        )
        var faultCount = 0
        writer.onWriterFault = {
            faultCount += 1
        }

        writer.start()
        let sessionDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: self.tempDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).first
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: sessionDirectory.lastPathComponent))
        let blockedURL = sessionDirectory
            .appendingPathComponent("in-progress", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString.lowercased())-1.m4a", isDirectory: false)
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: true)

        writer.append(self.samples(count: 4_000))
        try await self.waitForPendingCount(1, uploader: uploader)

        XCTAssertEqual(writer.droppedSamples, 2_400)
        XCTAssertEqual(writer.failedOpens, 3)
        XCTAssertEqual(faultCount, 1)
        writer.stop()
    }

    @MainActor
    func testFinalizationFreezesMetadataIntoQueuedManifest() async throws {
        let fileSystem = BlockingMoveTransferFileSystem()
        defer { fileSystem.releaseMove() }
        let uploader = self.makeUploader(fileSystem: fileSystem)
        let writer = OmiSegmentWriter(
            transferEnqueuer: uploader.transferEnqueuer,
            cacheRootURL: self.tempDirectory,
            clock: MockObserverClock()
        )
        let processID = UUID()
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: processID, sequence: 3, revision: 1)
        var connectionState = "connected"
        var acknowledgments: [[OmiSegmentMetadataToken]] = []
        writer.freezeSegmentMetadata = {
            OmiSegmentMetadataSnapshot(
                metadata: OmiSegmentMetadata(
                    connectionState: connectionState,
                    processID: processID,
                    reconnectCount: 2
                ),
                frozenTokens: [token]
            )
        }
        writer.acknowledgeSegmentMetadata = { tokens in
            acknowledgments.append(tokens)
        }

        writer.start()
        writer.append(self.samples(count: 3_200))
        writer.stop()

        try await self.waitForBlockedMove(fileSystem)
        let envelopeURL = try XCTUnwrap(self.files(withExtension: OmiPendingHandoffEnvelope.pathExtension).first)
        let envelope = try OmiPendingHandoffStore.read(from: envelopeURL)
        XCTAssertEqual(envelope.version, OmiPendingHandoffEnvelope.currentVersion)
        XCTAssertEqual(envelope.metadata?.connectionState, "connected")
        XCTAssertEqual(envelope.metadata?.processID, processID)
        XCTAssertEqual(envelope.frozenTokens, [token])
        connectionState = "disconnected"
        fileSystem.releaseMove()

        try await self.waitForPendingCount(1, uploader: uploader)
        let manifest = try XCTUnwrap(self.pendingChunks().first?.manifest)
        let metadata = try XCTUnwrap(OmiSegmentMetadata.from(meta: manifest.meta))
        XCTAssertEqual(metadata.connectionState, "connected")
        XCTAssertEqual(metadata.processID, processID)
        XCTAssertEqual(metadata.reconnectCount, 2)
        XCTAssertEqual(acknowledgments, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    @MainActor
    func testEnvelopeRemovalFailureDefersAcknowledgementToLaunchRecovery() async throws {
        let fileManager = HandoffRemovalFailingFileManager()
        let uploader = self.makeUploader()
        let writer = OmiSegmentWriter(
            transferEnqueuer: uploader.transferEnqueuer,
            cacheRootURL: self.tempDirectory,
            fileManager: fileManager,
            clock: MockObserverClock()
        )
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        var degradations: [String] = []
        writer.freezeSegmentMetadata = {
            OmiSegmentMetadataSnapshot(
                metadata: OmiSegmentMetadata(connectionState: "connected"),
                frozenTokens: [token]
            )
        }
        writer.acknowledgeSegmentMetadata = { acknowledgements.append($0) }
        writer.onHandoffDegradation = { degradations.append($0) }

        writer.start()
        writer.append(self.samples(count: 3_200))
        writer.stop()

        try await self.waitForPendingCount(1, uploader: uploader)
        try await self.waitFor("handoff removal degradation") {
            !degradations.isEmpty
        }
        let envelopeURL = try XCTUnwrap(self.files(withExtension: OmiPendingHandoffEnvelope.pathExtension).first)
        let sessionID = try XCTUnwrap(UUID(uuidString: envelopeURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent))
        XCTAssertEqual(acknowledgements, [])
        XCTAssertEqual(degradations, ["source=\(envelopeURL.path) reason=envelope removal failed"])

        let result = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: self.tempDirectory,
            transferEnqueuer: uploader.transferEnqueuer,
            acknowledgeTokens: { acknowledgements.append($0) },
            quarantineRootURL: self.tempDirectory.appendingPathComponent("quarantine", isDirectory: true),
            diagnosticLog: nil
        )

        XCTAssertEqual(result.unresolvedCount, 0)
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    }
}

private struct FinalizedChunkEvent: Sendable {
    let day: String
    let durationS: TimeInterval
    let identity: String
}

@MainActor
private final class OmiWriterTransferHarness {
    let transferEnqueuer: ObserverAudioTransferEnqueuer
    private let mirror: TransferStatusMirror

    init(rootURL: URL, fileSystem: (any TransferFileSystem)? = nil) {
        let harness = makeTransferCutoverHarness(rootURL: rootURL, fileSystem: fileSystem)
        self.transferEnqueuer = harness.enqueuer
        self.mirror = harness.mirror
    }

    var pendingCount: Int {
        self.mirror.sources[ObserverAudioTransferSource.omi]?.queuedCount ?? 0
    }
}

@MainActor
private extension OmiSegmentWriterTests {
    struct PendingChunk {
        let chunkID: String
        let audioURL: URL
        let sidecar: ChunkSidecar
        let manifest: TransferManifest
    }

    func makeUploader(fileSystem: (any TransferFileSystem)? = nil) -> OmiWriterTransferHarness {
        OmiWriterTransferHarness(
            rootURL: self.tempDirectory.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true),
            fileSystem: fileSystem
        )
    }

    func samples(count: Int) -> [Int16] {
        (0..<count).map { Int16($0 % 128) }
    }

    func waitForPendingCount(
        _ count: Int,
        uploader: OmiWriterTransferHarness,
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

    func waitFor(
        _ label: String,
        condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(label)", file: file, line: line)
    }

    func waitForBlockedMove(
        _ fileSystem: BlockingMoveTransferFileSystem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if fileSystem.hasBlockedMove {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for transfer spool move", file: file, line: line)
    }

    func pendingChunks() throws -> [PendingChunk] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let queuedRoot = self.tempDirectory
            .appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: queuedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return try entries.map { itemURL in
            let manifestURL = itemURL.appendingPathComponent(TransferSpool.manifestFilename, isDirectory: false)
            let manifest = try decoder.decode(TransferManifest.self, from: Data(contentsOf: manifestURL))
            let ingest = try XCTUnwrap(manifest.observerIngest)
            let sessionID = try XCTUnwrap(ingest.sessionID)
            let chunkIndex = try XCTUnwrap(ingest.chunkIndex)
            let sidecar = ChunkSidecar(
                segment: ingest.segment,
                day: ingest.day,
                chunkIndex: chunkIndex,
                startedAt: ingest.startedAt,
                durationS: ingest.durationS,
                sessionID: sessionID,
                mode: ingest.modeRawValue.flatMap(ObserverMode.init(rawValue:)) ?? .meeting,
                locationJSONL: nil
            )
            return PendingChunk(
                chunkID: "\(sessionID.uuidString.lowercased())-\(chunkIndex)",
                audioURL: itemURL.appendingPathComponent("audio.m4a", isDirectory: false),
                sidecar: sidecar,
                manifest: manifest
            )
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

private final class BlockingMoveTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let base = FoundationTransferFileSystem()
    private let blockedMove = OSAllocatedUnfairLock(initialState: false)
    private let moveRelease = DispatchSemaphore(value: 0)

    var hasBlockedMove: Bool {
        self.blockedMove.withLock { $0 }
    }

    func releaseMove() {
        self.moveRelease.signal()
    }

    func fileExists(atPath path: String) -> Bool {
        self.base.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.base.contentsOfDirectory(at: url)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        let shouldBlock = self.blockedMove.withLock { hasBlockedMove in
            guard !hasBlockedMove else { return false }
            hasBlockedMove = true
            return true
        }
        if shouldBlock {
            guard self.moveRelease.wait(timeout: .now() + 5) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        try self.base.replaceItem(at: originalURL, withItemAt: newURL)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try self.base.write(data, to: url, options: options)
    }

    func data(contentsOf url: URL) throws -> Data {
        try self.base.data(contentsOf: url)
    }

    func byteCount(at url: URL) throws -> Int {
        try self.base.byteCount(at: url)
    }

    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        try self.base.readChunks(at: url, chunkSize: chunkSize, consume)
    }

    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try self.base.writeStream(to: url, body)
    }
}

private final class HandoffRemovalFailingFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        if url.pathExtension == OmiPendingHandoffEnvelope.pathExtension {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }
}
