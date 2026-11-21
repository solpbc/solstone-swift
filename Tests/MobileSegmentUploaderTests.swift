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
        TransferURLProtocol.handler = { request, body in
            (transferTestResponse(for: request, statusCode: 200), transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type")))
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

        let envelope = try self.multipartEnvelope(in: body)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
        XCTAssertEqual(envelope["source"] as? String, ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(envelope["segment"] as? String, "090000_60")
        XCTAssertEqual(envelope["day"] as? String, "20260628")
        XCTAssertEqual(meta["segment_id"] as? String, segmentID.uuidString)
        XCTAssertEqual(meta["mode"] as? String, "meeting")
        XCTAssertNil(meta["chunk_index"])
        XCTAssertNil(meta["session_id"])
        XCTAssertNil(meta["battery_level"])
        XCTAssertNil(meta["battery_state"])
        XCTAssertNil(meta["low_power_mode"])
        XCTAssertNil(meta["power_sampled_at"])
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
        TransferURLProtocol.handler = { request, body in
            (transferTestResponse(for: request, statusCode: 200), transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type")))
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

    func testDeliveredResidueThatCannotRetireNeitherStallsThePassNorSendsAgain() async throws {
        let harness = self.makeHarness()
        let stuckID = UUID()
        let retiredID = UUID()
        let failedResidueID = UUID()
        let waitingID = UUID()
        let stuck = try self.writeSegment(store: harness.store, segmentID: stuckID, sources: [.audio])
        try Data("kept-part".utf8).write(to: harness.store.screenPartURL(in: stuck))
        try self.writeSegment(store: harness.store, segmentID: retiredID, sources: [.audio])
        try self.writeSegment(store: harness.store, segmentID: failedResidueID, sources: [.audio])
        let failedResidue = try harness.store.move(segmentID: failedResidueID, from: .pending, to: .failed)
        try Data("kept-part".utf8).write(to: harness.store.screenPartURL(in: failedResidue))
        try self.writeSegment(store: harness.store, segmentID: waitingID, sources: [.audio])
        for segmentID in [stuckID, retiredID, failedResidueID] {
            try harness.store.writeTombstone(segmentID: segmentID, kind: "uploaded", reason: "delivered", now: self.clock.now())
        }
        let losses = harness.uploader.journalEvents.rootURL.appendingPathComponent("losses", isDirectory: false)
        try FileManager.default.createDirectory(at: losses.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: losses)

        await harness.uploader.resumeFromDisk()

        XCTAssertTrue(harness.store.fileExists(stuck))
        XCTAssertTrue(harness.store.fileExists(failedResidue))
        XCTAssertFalse(harness.store.fileExists(harness.store.segmentDirectoryURL(.pending, segmentID: retiredID)))
        XCTAssertFalse(harness.store.fileExists(harness.store.segmentDirectoryURL(.pending, segmentID: waitingID)))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(harness.uploader.pendingCount, 0)
        XCTAssertEqual(harness.uploader.failedCount, 0)
        XCTAssertEqual(harness.uploader.onThisPhoneSnapshot(for: .audio), .loaded(items: []))

        await harness.uploader.resumeFromDisk()
        let afterSecondPass = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(afterSecondPass.count, 1)
        XCTAssertTrue(harness.store.fileExists(stuck))

        try FileManager.default.removeItem(at: losses)
        await harness.uploader.resumeFromDisk()

        XCTAssertFalse(harness.store.fileExists(stuck))
        XCTAssertFalse(harness.store.fileExists(failedResidue))
    }

    // MARK: - Phase 1 Startup & Foreground Unblock Tests

    func testScanStoreCountsFixtureParityCachedSummaryGenerationGuardDisabledAndGapNotice() async throws {
        let harness = self.makeHarness()
        let now = self.clock.now()

        // 1. pending/ multi-facet bundle ([.audio, .location, .screencast])
        let pendingMultiID = UUID()
        let pendingDir = try self.writeSegment(
            store: harness.store,
            segmentID: pendingMultiID,
            sources: [.audio, .location, .screencast]
        )

        // 2. failed/ with manifest.hasFinalizeFailure == false and failure.json stage == "schedule-gate"
        let scheduleGateID = UUID()
        _ = try self.writeSegment(store: harness.store, segmentID: scheduleGateID, sources: [.audio])
        let scheduleGateDir = try harness.store.move(segmentID: scheduleGateID, from: .pending, to: .failed)
        try harness.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "schedule gate",
                httpStatus: nil,
                transportError: nil,
                attemptCount: 1,
                stage: "schedule-gate",
                lastAttemptAt: now
            ),
            in: scheduleGateDir
        )

        // 3. failed/ with non-finalize stage == "upload" (failedCount += 1, finalizeFailedCount += 0)
        let uploadFailedID = UUID()
        _ = try self.writeSegment(store: harness.store, segmentID: uploadFailedID, sources: [.location])
        let uploadFailedDir = try harness.store.move(segmentID: uploadFailedID, from: .pending, to: .failed)
        try harness.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "http 500",
                httpStatus: 500,
                transportError: "server",
                attemptCount: 3,
                stage: "upload",
                lastAttemptAt: now
            ),
            in: uploadFailedDir
        )

        // 4. Unreadable manifest.json directories in pending/ and failed/ (counted in pendingCount/failedCount)
        let unreadablePendingDir = harness.store.segmentDirectoryURL(.pending, segmentID: UUID())
        try FileManager.default.createDirectory(at: unreadablePendingDir, withIntermediateDirectories: true)
        try Data("{corrupt".utf8).write(to: unreadablePendingDir.appendingPathComponent("manifest.json"))

        let unreadableFailedDir = harness.store.segmentDirectoryURL(.failed, segmentID: UUID())
        try FileManager.default.createDirectory(at: unreadableFailedDir, withIntermediateDirectories: true)
        try Data("{corrupt".utf8).write(to: unreadableFailedDir.appendingPathComponent("manifest.json"))

        // 5. Delivered residue (tombstones/uploaded/<UUID>.json) excluded from counts
        let deliveredResidueID = UUID()
        _ = try self.writeSegment(store: harness.store, segmentID: deliveredResidueID, sources: [.audio, .screencast])
        try harness.store.writeTombstone(segmentID: deliveredResidueID, kind: "uploaded", reason: "delivered", now: now)

        let scanned = MobileSegmentUploader.scanStoreCounts(rootURL: harness.store.rootURL)
        XCTAssertEqual(scanned.pendingCount, 2)
        XCTAssertEqual(scanned.failedCount, 3)
        XCTAssertEqual(scanned.finalizeFailedCount, 1)
        XCTAssertEqual(scanned.facetPending[.audio], 1)
        XCTAssertEqual(scanned.facetPending[.location], 1)
        XCTAssertEqual(scanned.facetPending[.screencast], 1)
        XCTAssertEqual(scanned.facetFailed[.audio], 1)
        XCTAssertEqual(scanned.facetFailed[.location], 1)
        XCTAssertEqual(scanned.facetFailed[.screencast, default: 0], 0)

        // O(1) memory lookup: refreshCounts() populates cached summaries; deleting manifest.json without refreshing
        // still returns the cached values.
        harness.uploader.refreshCounts()
        XCTAssertEqual(harness.uploader.summary(for: .audio).pendingCount, 1)
        XCTAssertEqual(harness.uploader.summary(for: .audio).failedCount, 1)
        XCTAssertEqual(harness.uploader.summary(for: .location).pendingCount, 1)
        XCTAssertEqual(harness.uploader.summary(for: .location).failedCount, 1)
        XCTAssertEqual(harness.uploader.summary(for: .screencast).pendingCount, 1)

        try FileManager.default.removeItem(at: pendingDir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(harness.uploader.summary(for: .audio).pendingCount, 1)
        XCTAssertEqual(harness.uploader.summary(for: .location).pendingCount, 1)
        XCTAssertEqual(harness.uploader.summary(for: .screencast).pendingCount, 1)

        // Injectable scanCounts seam proves stale scheduleRefreshCounts() / refreshCountsAsync()
        // never overwrites a newer synchronous refreshCounts().
        let scanEntered = DispatchSemaphore(value: 0)
        let scanRelease = DispatchSemaphore(value: 0)
        let scanMode = OSAllocatedUnfairLock<Int>(initialState: 0)
        let staleCounts = MobileSegmentStoreCounts(pendingCount: 99, failedCount: 99, finalizeFailedCount: 99, facetPending: [.audio: 99], facetFailed: [:])
        let freshCounts = MobileSegmentStoreCounts(pendingCount: 4, failedCount: 1, finalizeFailedCount: 0, facetPending: [.audio: 4], facetFailed: [.audio: 1])
        harness.uploader.scanCounts = { _ in
            let mode = scanMode.withLock { m -> Int in
                let cur = m
                if cur == 0 { m = 1 }
                return cur
            }
            if mode == 0 {
                scanEntered.signal()
                scanRelease.wait()
                return staleCounts
            }
            return freshCounts
        }
        harness.uploader.scheduleRefreshCounts()
        let enteredResult = await TestSemaphore.wait(scanEntered, timeout: .now() + 5)
        XCTAssertEqual(enteredResult, .success)
        harness.uploader.refreshCounts()
        XCTAssertEqual(harness.uploader.pendingCount, 4)
        XCTAssertEqual(harness.uploader.summary(for: .audio).pendingCount, 4)
        scanRelease.signal()
        await harness.uploader.waitForCountsRefreshForTesting()
        XCTAssertEqual(harness.uploader.pendingCount, 4, "stale scheduleRefreshCounts must not overwrite newer sync refreshCounts")

        // Same check for refreshCountsAsync().
        scanMode.withLock { $0 = 0 }
        let asyncRefreshTask = Task { await harness.uploader.refreshCountsAsync() }
        let enteredResult2 = await TestSemaphore.wait(scanEntered, timeout: .now() + 5)
        XCTAssertEqual(enteredResult2, .success)
        harness.uploader.refreshCounts()
        scanRelease.signal()
        await asyncRefreshTask.value
        XCTAssertEqual(harness.uploader.pendingCount, 4, "stale refreshCountsAsync must not overwrite newer sync refreshCounts")

        // Disabled uploader does not touch disk.
        let disabledStore = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("DisabledStore", isDirectory: true))
        let disabledUploader = MobileSegmentUploader(
            store: disabledStore,
            clock: self.clock,
            storageDisabledReason: "container unavailable",
            deferInitialCountScan: true
        )
        let disabledScanCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        disabledUploader.scanCounts = { _ in
            disabledScanCount.withLock { $0 += 1 }
            return staleCounts
        }
        disabledUploader.refreshCounts()
        disabledUploader.scheduleRefreshCounts()
        await disabledUploader.refreshCountsAsync()
        XCTAssertEqual(disabledScanCount.withLock { $0 }, 0)

        // refreshJournalGap() and refreshJournalGapNotice() (including under Task.isCancelled == true) update journalGapNotice.
        harness.uploader.scanCounts = MobileSegmentUploader.scanStoreCounts
        let lossID = UUID()
        try harness.uploader.journalEvents.openGate(now: now)
        try harness.uploader.journalEvents.recordLoss(
            segmentID: lossID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: now,
            now: now
        )
        let holder = MobileSegmentTransferHolder(
            transferEngine: harness.engine,
            mirror: TransferStatusMirror(),
            uploader: harness.uploader
        )
        holder.refreshJournalGap()
        await harness.uploader.waitForJournalGapNotice()
        XCTAssertTrue(harness.uploader.journalGapNotice.isShowing)

        // Under Task.isCancelled == true, refreshJournalGapNotice() still refreshes notice & counts.
        try harness.uploader.journalEvents.markAllEventsSeen()
        let cancelledNoticeTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            await harness.uploader.refreshJournalGapNotice()
        }
        await cancelledNoticeTask.value
        XCTAssertFalse(harness.uploader.journalGapNotice.isShowing)

        // Cancelled migrateLegacyMobileItems() flushes deferred counts when suppressed refreshes occurred.
        let legacyRoot = self.tempDirectory.appendingPathComponent("LegacyLocCancel", isDirectory: true)
        let legacyPending = legacyRoot.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyPending, withIntermediateDirectories: true)
        let legacyPayload = Data(#"{"type":"solstone.location.segment","started_at":"2026-06-28T09:00:00Z","ended_at":"2026-06-28T09:01:00Z","day":"20260628","segment":"090000_60"}"#.utf8)
        try legacyPayload.write(to: legacyPending.appendingPathComponent("20260628-090000_60.jsonl"))
        try legacyPayload.write(to: legacyPending.appendingPathComponent("20260628-090100_60.jsonl"))
        var cancelMigrateTask: Task<Void, Never>?
        var checkpoints = 0
        let cancelCooperator = MaintenanceCooperator(chunkSize: 1) {
            checkpoints += 1
            if checkpoints == 2 {
                // First legacy file already migrated & called suppressed refreshCounts(); cancel before file 2 & resumeFromDisk().
                cancelMigrateTask?.cancel()
            }
        }
        let freshCancelHarness = self.makeHarness(
            transferRootName: "MigrateCancelTransfer",
            store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MigrateCancelBox/MobileSegment", isDirectory: true)),
            cooperator: cancelCooperator
        )
        XCTAssertEqual(freshCancelHarness.uploader.pendingCount, 0)
        cancelMigrateTask = Task {
            await freshCancelHarness.uploader.migrateLegacyMobileItems(locationCacheRootURL: legacyRoot)
        }
        await cancelMigrateTask?.value
        await freshCancelHarness.uploader.waitForCountsRefreshForTesting()
        XCTAssertFalse(freshCancelHarness.uploader.journalEvents.isGateOpen, "cancelled migration must not run resumeFromDisk")
        XCTAssertEqual(freshCancelHarness.uploader.pendingCount, 1, "cancelled migrateLegacyMobileItems must still flush deferred counts")
    }

    func testPruneJournalEventsRunsOffMainAndOncePerResumeFromDisk() async throws {
        let harness = self.makeHarness()
        let stats = OSAllocatedUnfairLock<(count: Int, offMain: [Bool])>(initialState: (0, []))
        harness.uploader.pruneJournalEvents = { store, now in
            stats.withLock {
                $0.count += 1
                $0.offMain.append(!Thread.isMainThread)
            }
            store.pruneForPass(now: now)
        }

        await harness.uploader.resumeFromDisk()

        let result = stats.withLock { $0 }
        XCTAssertEqual(result.count, 1, "resumeFromDisk() must prune journal events exactly once")
        XCTAssertEqual(result.offMain, [true], "pruneForPass must execute off @MainActor")
    }

    func testResumeFromDiskFIFOSerializationAndCancellationHandoffSafety() async throws {
        // (a) Cancelling queued Caller 2 wakes Caller 2 promptly without opening the gate or stranding Caller 3.
        do {
            let harness = self.makeHarness(
                transferRootName: "FIFO-A-Transfer",
                store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("FIFO-A/MobileSegment", isDirectory: true))
            )
            let pass1Entered = DispatchSemaphore(value: 0)
            let pass1Release = DispatchSemaphore(value: 0)
            let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
            harness.uploader.pruneJournalEvents = { store, now in
                let n = callCount.withLock { c -> Int in c += 1; return c }
                if n == 1 {
                    pass1Entered.signal()
                    pass1Release.wait()
                }
                store.pruneForPass(now: now)
            }

            let caller1 = Task { await harness.uploader.resumeFromDisk() }
            let entered1 = await TestSemaphore.wait(pass1Entered, timeout: .now() + 5)
            XCTAssertEqual(entered1, .success)

            let caller2 = Task { await harness.uploader.resumeFromDisk() }
            let caller3 = Task { await harness.uploader.resumeFromDisk() }
            await Task.yield()

            // Cancel queued Caller 2 while Caller 1 is still active.
            caller2.cancel()
            await caller2.value
            XCTAssertFalse(harness.uploader.journalEvents.isGateOpen, "cancelled queued Caller 2 must not open gate")

            pass1Release.signal()
            await caller1.value
            await caller3.value
            XCTAssertTrue(harness.uploader.journalEvents.isGateOpen)
            XCTAssertEqual(callCount.withLock { $0 }, 2, "Caller 1 and Caller 3 run; cancelled Caller 2 skipped")
        }

        // (b) Cancelling active Caller 1 mid-pass releases Caller 2 to complete and open the gate once.
        do {
            let harness = self.makeHarness(
                transferRootName: "FIFO-B-Transfer",
                store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("FIFO-B/MobileSegment", isDirectory: true))
            )
            let pass1Entered = DispatchSemaphore(value: 0)
            let pass1Release = DispatchSemaphore(value: 0)
            let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
            harness.uploader.pruneJournalEvents = { store, now in
                let n = callCount.withLock { c -> Int in c += 1; return c }
                if n == 1 {
                    pass1Entered.signal()
                    pass1Release.wait()
                }
                store.pruneForPass(now: now)
            }

            let caller1 = Task { await harness.uploader.resumeFromDisk() }
            let entered1 = await TestSemaphore.wait(pass1Entered, timeout: .now() + 5)
            XCTAssertEqual(entered1, .success)

            let caller2 = Task { await harness.uploader.resumeFromDisk() }
            await Task.yield()

            caller1.cancel()
            pass1Release.signal()
            await caller1.value
            await caller2.value
            XCTAssertTrue(harness.uploader.journalEvents.isGateOpen)
            XCTAssertEqual(callCount.withLock { $0 }, 2)
        }

        // (c1) Cancelling Caller 2 right after Caller 1's handoff releases lock so Caller 3 completes and opens gate.
        do {
            let harness = self.makeHarness(
                transferRootName: "FIFO-C1-Transfer",
                store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("FIFO-C1/MobileSegment", isDirectory: true))
            )
            let pass1Entered = DispatchSemaphore(value: 0)
            let pass1Release = DispatchSemaphore(value: 0)
            let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
            harness.uploader.pruneJournalEvents = { store, now in
                let n = callCount.withLock { c -> Int in c += 1; return c }
                if n == 1 {
                    pass1Entered.signal()
                    pass1Release.wait()
                }
                store.pruneForPass(now: now)
            }

            let caller1 = Task { await harness.uploader.resumeFromDisk() }
            let entered1 = await TestSemaphore.wait(pass1Entered, timeout: .now() + 5)
            XCTAssertEqual(entered1, .success)

            let caller2 = Task { await harness.uploader.resumeFromDisk() }
            let caller3 = Task { await harness.uploader.resumeFromDisk() }
            await Task.yield()

            var handedOffCount = 0
            harness.uploader.onResumeSlotHandedOff = {
                handedOffCount += 1
                if handedOffCount == 1 {
                    // Cancel Caller 2 synchronously right after ownership was handed off to it!
                    caller2.cancel()
                }
            }
            caller1.cancel()
            pass1Release.signal()
            await caller1.value
            await caller2.value
            await caller3.value
            XCTAssertEqual(handedOffCount, 2, "Caller 2 must hand off lock to Caller 3 on cancel-after-handoff")
            XCTAssertTrue(harness.uploader.journalEvents.isGateOpen)
            XCTAssertEqual(callCount.withLock { $0 }, 2, "Caller 1 (cancelled) + Caller 3 (completed); Caller 2 exited before prune")
        }

        // (c2) Pre-cancelled Caller 2 never takes or strands the lock for Caller 3.
        do {
            let harness = self.makeHarness(
                transferRootName: "FIFO-C2-Transfer",
                store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("FIFO-C2/MobileSegment", isDirectory: true))
            )
            let preCancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await harness.uploader.resumeFromDisk()
            }
            await preCancelled.value
            XCTAssertFalse(harness.uploader.journalEvents.isGateOpen)

            await harness.uploader.resumeFromDisk()
            XCTAssertTrue(harness.uploader.journalEvents.isGateOpen)
        }
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
