// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentUploaderTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        TransferURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentUploaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        super.tearDown()
    }

    func testMultiFacetEnqueueProducesOneTransferItemWithThreePartsAndMobileMetadata() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 200), Data("ok".utf8))
        }
        let harness = self.makeHarness(endpointAvailable: true)
        let segmentID = UUID()
        try self.writeSegment(
            store: harness.store,
            segmentID: segmentID,
            sources: [.audio, .location, .screencast]
        )

        try await harness.engine.start()
        await harness.uploader.resumeFromDisk()

        try await transferTestWaitFor("mobile multipart") {
            TransferURLProtocol.bodies.count == 1
        }
        let request = try XCTUnwrap(TransferURLProtocol.requests.first)
        let body = try XCTUnwrap(TransferURLProtocol.bodies.first)
        XCTAssertNotNil(transferTestBoundaryItemID(from: request))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path
        ))

        let meta = try self.multipartMeta(in: body)
        XCTAssertEqual(try self.multipartValue(named: "platform", in: body), "ios")
        XCTAssertEqual(try self.multipartValue(named: "segment", in: body), "090000_60")
        XCTAssertEqual(try self.multipartValue(named: "day", in: body), "20260628")
        XCTAssertEqual(meta["segment_id"] as? String, segmentID.uuidString)
        XCTAssertEqual(meta["mode"] as? String, "meeting")
        XCTAssertNil(meta["chunk_index"])
        XCTAssertNil(meta["session_id"])
        XCTAssertEqual((meta["sources"] as? [String])?.sorted(), ["audio", "location", "screencast"])
        let stringBody = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(stringBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(stringBody.contains(#"filename="location.jsonl""#))
        XCTAssertTrue(stringBody.contains(#"filename="screen.mp4""#))
        XCTAssertTrue(stringBody.contains("Content-Type: video/mp4"))
    }

    func testPartialFacetSegmentsEnqueueOnlyDeclaredExistingParts() async throws {
        let harness = self.makeHarness()
        let cases: [(Set<MobileSegmentSource>, Set<String>)] = [
            ([.audio], ["audio"]),
            ([.location], ["location"]),
            ([.screencast], ["screencast"]),
        ]

        for (sources, partIDs) in cases {
            let segmentID = UUID()
            try self.writeSegment(store: harness.store, segmentID: segmentID, sources: sources)
            await harness.uploader.resumeFromDisk()
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
            let snapshot = try XCTUnwrap(
                snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID }
            )
            XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), partIDs)
            XCTAssertEqual(Set(snapshot.manifest.observerIngest?.sources ?? []), Set(sources.map(\.rawValue)))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path
            ))
        }
    }

    func testMultiPartEnqueueFailureLeavesPendingArtifactsAndLaterPassReenqueues() async throws {
        let failingFileSystem = MoveFailingTransferFileSystem(failOnMove: 2)
        let transferRootName = "retry-transfer"
        let failingHarness = self.makeHarness(
            transferRootName: transferRootName,
            fileSystem: failingFileSystem
        )
        let segmentID = UUID()
        try self.writeSegment(
            store: failingHarness.store,
            segmentID: segmentID,
            sources: [.audio, .location, .screencast]
        )

        await failingHarness.uploader.resumeFromDisk()

        let pendingDirectory = failingHarness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failingHarness.store.audioURL(in: pendingDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failingHarness.store.locationURL(in: pendingDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failingHarness.store.screenURL(in: pendingDirectory).path))
        XCTAssertFalse(self.tempPathExists(containing: segmentID.uuidString))

        let successHarness = self.makeHarness(
            transferRootName: transferRootName,
            store: failingHarness.store
        )
        try await successHarness.engine.start()
        await successHarness.uploader.resumeFromDisk()

        let snapshots = await successHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.segmentID, segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
    }

    func testMissingDeclaredFinalizedArtifactRoutesWholeSegmentToScheduleGateFailure() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let pendingDirectory = try self.writeSegment(
            store: harness.store,
            segmentID: segmentID,
            sources: [.audio, .location]
        )
        try FileManager.default.removeItem(at: harness.store.locationURL(in: pendingDirectory))

        await harness.uploader.resumeFromDisk()

        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedDirectory.path))
        let failure = try XCTUnwrap(harness.store.loadFailure(in: failedDirectory))
        XCTAssertEqual(failure.stage, "schedule-gate")
        XCTAssertTrue(failure.reason.contains("finalized artifact missing"))
        XCTAssertEqual(try harness.store.readManifest(in: failedDirectory).upload, .failed)
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testDeliveredTombstoneWriteIsIdempotentAndRetiresResidue() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()

        try harness.uploader.writeUploadedTombstone(segmentID: segmentID)
        try harness.uploader.writeUploadedTombstone(segmentID: segmentID)

        let tombstoneURL = harness.store.tombstoneDirectory(kind: "uploaded")
            .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstoneURL.path))
        XCTAssertTrue((try? harness.store.list(.pending))?.isEmpty ?? true)
        XCTAssertTrue((try? harness.store.list(.failed))?.isEmpty ?? true)
    }

    func testConcurrentResumeAdoptsPendingSegmentOnlyOnce() async throws {
        let harness = self.makeHarness(cooperator: MaintenanceCooperator(chunkSize: 1))
        let segmentID = UUID()
        try self.writeSegment(store: harness.store, segmentID: segmentID, sources: [.audio])

        async let first: Void = harness.uploader.resumeFromDisk()
        async let second: Void = harness.uploader.resumeFromDisk()
        _ = await (first, second)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.itemID, segmentID)
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.segmentID, segmentID)
        XCTAssertFalse(harness.store.fileExists(
            harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        ))
        XCTAssertFalse(harness.store.fileExists(
            harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        ))
    }

    func testTwoUploaderInstancesAtomicallyAdoptOneSegment() async throws {
        let harness = self.makeHarness(cooperator: MaintenanceCooperator(chunkSize: 1))
        let secondUploader = MobileSegmentUploader(
            transferEngine: harness.engine,
            store: harness.store,
            clock: self.clock,
            cooperator: MaintenanceCooperator(chunkSize: 1)
        )
        let segmentID = UUID()
        try self.writeSegment(store: harness.store, segmentID: segmentID, sources: [.audio])

        async let first: Void = harness.uploader.resumeFromDisk()
        async let second: Void = secondUploader.resumeFromDisk()
        _ = await (first, second)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.itemID, segmentID)
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.segmentID, segmentID)
        XCTAssertFalse(harness.store.fileExists(
            harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        ))
        XCTAssertFalse(harness.store.fileExists(
            harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        ))
    }

    func testLegacyRandomTransferOwnershipRetiresFailedResidue() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeSegment(
            store: harness.store,
            segmentID: segmentID,
            sources: [.audio]
        )
        let mobileManifest = try harness.store.readManifest(in: failedDirectory)
        _ = try harness.store.move(segmentID: segmentID, from: .pending, to: .failed)
        let legacyItemID = UUID()
        let transferManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: legacyItemID,
            manifest: mobileManifest,
            now: self.clock.now(),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
        _ = try await harness.engine.enqueue(
            manifest: transferManifest,
            payloads: ["audio": Data("audio-bytes".utf8)]
        )

        await harness.uploader.resumeFromDisk()

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.itemID, legacyItemID)
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.segmentID, segmentID)
        XCTAssertFalse(harness.store.fileExists(
            harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        ))
    }

    func testMissingTransferPayloadNeverRetiresIntactProducerCopy() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let pendingDirectory = try self.writeSegment(
            store: harness.store,
            segmentID: segmentID,
            sources: [.audio]
        )
        let mobileManifest = try harness.store.readManifest(in: pendingDirectory)
        let transferManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: segmentID,
            manifest: mobileManifest,
            now: self.clock.now(),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
        _ = try await harness.engine.enqueue(
            manifest: transferManifest,
            payloads: ["audio": Data("audio-bytes".utf8)]
        )
        let transferPayload = self.tempDirectory
            .appendingPathComponent("Transfers/queued/\(segmentID.uuidString)/audio.m4a")
        try FileManager.default.removeItem(at: transferPayload)

        await harness.uploader.resumeFromDisk()

        XCTAssertTrue(harness.store.fileExists(pendingDirectory))
        XCTAssertTrue(harness.store.fileExists(harness.store.audioURL(in: pendingDirectory)))
    }

    func testLegacyPayloadMismatchNeverRetiresIntactProducerCopy() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 200), Data("ok".utf8))
        }
        let harness = self.makeHarness(endpointAvailable: true)
        try await harness.engine.initialize()
        let segmentID = UUID()
        let failedDirectory = try self.writeSegment(
            store: harness.store,
            segmentID: segmentID,
            sources: [.audio]
        )
        let mobileManifest = try harness.store.readManifest(in: failedDirectory)
        _ = try harness.store.move(segmentID: segmentID, from: .pending, to: .failed)
        let legacyManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: UUID(),
            manifest: mobileManifest,
            now: self.clock.now(),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
        _ = try await harness.engine.enqueue(
            manifest: legacyManifest,
            payloads: ["audio": Data("different-bytes".utf8)]
        )

        await harness.uploader.resumeFromDisk()

        await harness.engine.enableDispatch()
        try await transferTestWaitFor("independent legacy mismatch dispatch") {
            TransferURLProtocol.requests.count == 1
        }

        let retained = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertTrue(harness.store.fileExists(retained))
        XCTAssertTrue(harness.store.fileExists(harness.store.audioURL(in: retained)))
    }

    func testLegacyManifestMismatchNeverRetiresIntactProducerCopy() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeSegment(
            store: harness.store,
            segmentID: segmentID,
            sources: [.audio]
        )
        let mobileManifest = try harness.store.readManifest(in: failedDirectory)
        _ = try harness.store.move(segmentID: segmentID, from: .pending, to: .failed)
        var legacyManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: UUID(),
            manifest: mobileManifest,
            now: self.clock.now(),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
        legacyManifest.observerIngest?.day = "20991231"
        _ = try await harness.engine.enqueue(
            manifest: legacyManifest,
            payloads: ["audio": Data("audio-bytes".utf8)]
        )

        await harness.uploader.resumeFromDisk()

        let retained = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertTrue(harness.store.fileExists(retained))
        XCTAssertTrue(harness.store.fileExists(harness.store.audioURL(in: retained)))
    }

    func testUploadedTombstoneRetiresStalePendingAndFailedResidue() async throws {
        let harness = self.makeHarness()
        let pendingID = UUID()
        let failedID = UUID()
        try self.writeSegment(store: harness.store, segmentID: pendingID, sources: [.audio])
        _ = try self.writeSegment(store: harness.store, segmentID: failedID, sources: [.audio])
        _ = try harness.store.move(segmentID: failedID, from: .pending, to: .failed)
        try harness.store.writeTombstone(segmentID: pendingID, kind: "uploaded", reason: "delivered", now: self.clock.now())
        try harness.store.writeTombstone(segmentID: failedID, kind: "uploaded", reason: "delivered", now: self.clock.now())

        await harness.uploader.resumeFromDisk()

        XCTAssertFalse(harness.store.fileExists(
            harness.store.segmentDirectoryURL(.pending, segmentID: pendingID)
        ))
        XCTAssertFalse(harness.store.fileExists(
            harness.store.segmentDirectoryURL(.failed, segmentID: failedID)
        ))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertTrue(snapshots.isEmpty)
    }
}

private extension MobileSegmentUploaderTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
        let engine: TransferEngine
    }

    func makeHarness(
        endpointAvailable: Bool = false,
        transferRootName: String = "Transfers",
        store: MobileSegmentStore? = nil,
        fileSystem: (any TransferFileSystem)? = nil,
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) -> Harness {
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent(transferRootName, isDirectory: true),
            fileSystem: fileSystem,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: endpointAvailable
                ? TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
                : TransferCutoverEndpointResolver()
        )
        let store = store ?? MobileSegmentStore(
            rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        )
        return Harness(
            uploader: MobileSegmentUploader(
                transferEngine: transferHarness.engine,
                store: store,
                clock: self.clock,
                cooperator: cooperator
            ),
            store: store,
            engine: transferHarness.engine
        )
    }

    @discardableResult
    func writeSegment(
        store: MobileSegmentStore,
        segmentID: UUID,
        sources: Set<MobileSegmentSource>
    ) throws -> URL {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: sources,
            activeSourceSetVersion: 1
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending
        let activeDirectory = try store.createActive(manifest: manifest)
        for source in sources.sorted(by: { $0.rawValue < $1.rawValue }) {
            let artifactURL = store.artifactURL(in: activeDirectory, source: source)
            try Data("\(source.rawValue)-bytes".utf8).write(to: artifactURL, options: .atomic)
            manifest = try store.readManifest(in: activeDirectory)
            try store.writeOutcome(
                MobileSegmentSourceResolution(
                    state: .finalizedArtifact,
                    artifactFilename: artifactURL.lastPathComponent,
                    bytes: store.fileSize(at: artifactURL),
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationS: 60,
                    mode: source == .audio ? .meeting : nil,
                    fixCount: source == .location ? 1 : nil
                ),
                source: source,
                manifest: &manifest,
                in: activeDirectory,
                now: endedAt
            )
        }
        return try store.move(segmentID: segmentID, from: .active, to: .pending)
    }

    func tempPathExists(containing needle: String) -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileSegmentTransferEnqueue", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator where url.path.contains(needle) {
            return true
        }
        return false
    }
}

private final class MoveFailingTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let delegate = FoundationTransferFileSystem()
    private let state: OSAllocatedUnfairLock<(moveCount: Int, failOnMove: Int)>

    init(failOnMove: Int) {
        self.state = OSAllocatedUnfairLock(initialState: (moveCount: 0, failOnMove: failOnMove))
    }

    func fileExists(atPath path: String) -> Bool {
        self.delegate.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.delegate.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.delegate.contentsOfDirectory(at: url)
    }

    func removeItem(at url: URL) throws {
        try self.delegate.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        let shouldFail = self.state.withLock { state in
            state.moveCount += 1
            return state.moveCount == state.failOnMove
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try self.delegate.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        try self.delegate.replaceItem(at: originalURL, withItemAt: newURL)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try self.delegate.write(data, to: url, options: options)
    }

    func data(contentsOf url: URL) throws -> Data {
        try self.delegate.data(contentsOf: url)
    }

    func byteCount(at url: URL) throws -> Int {
        try self.delegate.byteCount(at: url)
    }

    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        try self.delegate.readChunks(at: url, chunkSize: chunkSize, consume)
    }

    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try self.delegate.writeStream(to: url, body)
    }
}
