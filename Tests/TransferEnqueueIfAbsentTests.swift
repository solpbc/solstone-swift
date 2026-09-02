// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class TransferEnqueueIfAbsentTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferEnqueueIfAbsentTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
    }

    @MainActor func testAlreadyPresentInQueuedDoesNotCreateATwin() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let itemID = UUID()
        let manifest = self.omiManifest(itemID: itemID)
        let firstPayload = try self.payloadFileURLs(contents: "first")
        let firstURL = try XCTUnwrap(firstPayload["audio"])
        let first = try await harness.engine.enqueueIfAbsent(
            manifest: manifest,
            payloadFileURLs: firstPayload
        )
        XCTAssertEqual(first, .enqueued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let secondPayload = try self.payloadFileURLs(contents: "first")
        let secondURL = try XCTUnwrap(secondPayload["audio"])
        let second = try await harness.engine.enqueueIfAbsent(
            manifest: manifest,
            payloadFileURLs: secondPayload
        )
        XCTAssertEqual(second, .alreadyPresent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.map(\.itemID), [itemID])
        XCTAssertEqual(snapshots.first?.manifest.diskState, .queued)
    }

    @MainActor func testAlreadyPresentInAttentionDoesNotCreateATwin() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let itemID = UUID()
        let manifest = self.omiManifest(itemID: itemID)
        _ = try await harness.engine.enqueueAttention(
            manifest: manifest,
            payloadFileURLs: try self.payloadFileURLs(contents: "attention"),
            reason: "test",
            detail: "test"
        )
        let retryPayload = try self.payloadFileURLs(contents: "attention")
        let retryURL = try XCTUnwrap(retryPayload["audio"])
        let retry = try await harness.engine.enqueueIfAbsent(
            manifest: manifest,
            payloadFileURLs: retryPayload
        )
        XCTAssertEqual(retry, .alreadyPresent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retryURL.path))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.map(\.itemID), [itemID])
        XCTAssertEqual(snapshots.first?.manifest.diskState, .attention)
    }

    @MainActor func testNotFoundEnqueuesAndMovesTheProducerFile() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let itemID = UUID()
        let payload = try self.payloadFileURLs(contents: "fresh")
        let producerURL = try XCTUnwrap(payload["audio"])
        let outcome = try await harness.engine.enqueueIfAbsent(
            manifest: self.omiManifest(itemID: itemID),
            payloadFileURLs: payload
        )
        XCTAssertEqual(outcome, .enqueued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: producerURL.path))
        let snapshot = await harness.engine.itemSnapshot(itemID: itemID)
        let queued = try XCTUnwrap(snapshot)
        XCTAssertEqual(queued.manifest.diskState, .queued)
        let payloadURL = await harness.engine.payloadFileURL(itemID: itemID, partID: "audio")
        XCTAssertNotNil(payloadURL)
    }

    @MainActor func testConflictThrowsWithoutATwin() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let itemID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: self.omiManifest(itemID: itemID, chunkIndex: 0),
            payloadFileURLs: try self.payloadFileURLs(contents: "owned")
        )
        do {
            _ = try await harness.engine.enqueueIfAbsent(
                manifest: self.omiManifest(itemID: itemID, chunkIndex: 1),
                payloadFileURLs: try self.payloadFileURLs(contents: "conflict")
            )
            XCTFail("expected unverified ownership")
        } catch let error as TransferEnqueueIfAbsentError {
            guard case .unverifiedOwnership(.conflict) = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.map(\.itemID), [itemID])
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.chunkIndex, 0)
    }

    @MainActor func testStagingOnlyThrowsWithoutCommitting() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let itemID = UUID()
        let spool = TransferSpool(rootURL: self.rootURL)
        _ = try spool.stage(
            manifest: self.omiManifest(itemID: itemID),
            payloads: ["audio": Data("staged".utf8)]
        )
        do {
            _ = try await harness.engine.enqueueIfAbsent(
                manifest: self.omiManifest(itemID: itemID),
                payloadFileURLs: try self.payloadFileURLs(contents: "retry")
            )
            XCTFail("expected unverified ownership")
        } catch let error as TransferEnqueueIfAbsentError {
            XCTAssertEqual(error, .unverifiedOwnership(.stagingOnly))
        }
        let missing = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNil(missing)
    }

    @MainActor func testNilEquivalentObserverSegmentIDMatchesItemIDOnly() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let segmentID = UUID()
        let existingID = UUID()
        var existing = self.omiManifest(itemID: existingID)
        existing.observerIngest?.segmentID = segmentID
        _ = try await harness.engine.enqueue(
            manifest: existing,
            payloadFileURLs: try self.payloadFileURLs(contents: "existing")
        )
        let adoptedID = UUID()
        var adopted = self.omiManifest(itemID: adoptedID)
        adopted.observerIngest?.segmentID = segmentID
        let outcome = try await harness.engine.enqueueIfAbsent(
            manifest: adopted,
            equivalentObserverSegmentID: nil,
            payloadFileURLs: try self.payloadFileURLs(contents: "adopted")
        )
        XCTAssertEqual(outcome, .enqueued)
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(Set(snapshots.map(\.itemID)), Set([existingID, adoptedID]))
    }

    @MainActor func testEquivalentObserverSegmentIDFindsAnAlternateOwner() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let segmentID = UUID()
        let existingID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        var existing = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: existingID, sidecar: sidecar)
        existing.observerIngest?.segmentID = segmentID
        _ = try await harness.engine.enqueue(
            manifest: existing,
            payloadFileURLs: try self.payloadFileURLs(contents: "existing")
        )
        let adoptedID = UUID()
        var adopted = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: adoptedID, sidecar: sidecar)
        adopted.observerIngest?.segmentID = segmentID
        let retryPayload = try self.payloadFileURLs(contents: "existing")
        let retryURL = try XCTUnwrap(retryPayload["audio"])
        let outcome = try await harness.engine.enqueueIfAbsent(
            manifest: adopted,
            equivalentObserverSegmentID: segmentID,
            payloadFileURLs: retryPayload
        )
        XCTAssertEqual(outcome, .alreadyPresent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retryURL.path))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.map(\.itemID), [existingID])
    }

    @MainActor func testRelinquishRemovesQueuedItemWithoutDropping() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let itemID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: self.omiManifest(itemID: itemID),
            payloadFileURLs: try self.payloadFileURLs(contents: "relinquish")
        )
        await harness.engine.relinquish(itemID: itemID)
        let missing = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNil(missing)
        let dropped = await harness.engine.snapshot()
        XCTAssertEqual(dropped.counters.droppedCount, 0)
        await harness.engine.relinquish(itemID: itemID)
    }

    @MainActor func testMoveToAttentionIsANoOpForMissingAndAlreadyAttentionItems() async throws {
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        let queuedID = UUID()
        let attentionID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: self.omiManifest(itemID: queuedID),
            payloadFileURLs: try self.payloadFileURLs(contents: "queued")
        )
        _ = try await harness.engine.enqueueAttention(
            manifest: self.omiManifest(itemID: attentionID),
            payloadFileURLs: try self.payloadFileURLs(contents: "attention"),
            reason: "existing",
            detail: "existing"
        )
        await harness.engine.moveToAttention(
            itemID: queuedID,
            reason: "omi_producer_cleanup_failed",
            detail: "envelope removal failed"
        )
        await harness.engine.moveToAttention(
            itemID: attentionID,
            reason: "omi_producer_cleanup_failed",
            detail: "envelope removal failed"
        )
        await harness.engine.moveToAttention(
            itemID: UUID(),
            reason: "omi_producer_cleanup_failed",
            detail: "envelope removal failed"
        )
        let queuedSnapshot = await harness.engine.itemSnapshot(itemID: queuedID)
        let queued = try XCTUnwrap(queuedSnapshot)
        XCTAssertEqual(queued.manifest.diskState, .attention)
        XCTAssertEqual(queued.manifest.attention?.reason, "omi_producer_cleanup_failed")
        let attentionSnapshot = await harness.engine.itemSnapshot(itemID: attentionID)
        let attention = try XCTUnwrap(attentionSnapshot)
        XCTAssertEqual(attention.manifest.attention?.reason, "existing")
    }

    @MainActor private func makeHarness() -> (
        engine: TransferEngine,
        mirror: TransferStatusMirror,
        enqueuer: ObserverAudioTransferEnqueuer,
        omi: OmiUploaderHolder,
        watch: WatchUploaderHolder
    ) {
        makeTransferCutoverHarness(rootURL: self.rootURL)
    }

    private func omiManifest(itemID: UUID, chunkIndex: Int = 0) -> TransferManifest {
        ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: itemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: chunkIndex, startedAt: Date())
        )
    }

    private func payloadFileURLs(contents: String) throws -> [String: URL] {
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        let url = self.rootURL.appendingPathComponent("payload-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
        return ["audio": url]
    }
}
