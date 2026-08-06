// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class TransferOwnerConflictPreflightTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferOwnerConflictPreflightTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    func testInitializeHoldsRawQueuedAttentionTwinWithoutMutatingEitherOwner() throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        let itemID = UUID()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: itemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        )
        let staged = try spool.stage(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        let queued = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        let attentionURL = spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: queued.directoryURL, to: attentionURL)
        let queuedBytes = try Data(contentsOf: queued.directoryURL.appendingPathComponent("audio.m4a"))
        let attentionBytes = try Data(contentsOf: attentionURL.appendingPathComponent("audio.m4a"))

        let snapshot = try spool.initialize()

        XCTAssertEqual(snapshot.conflictedItemIDs, Set([itemID]))
        XCTAssertTrue(snapshot.queued.isEmpty)
        XCTAssertTrue(snapshot.attention.isEmpty)
        XCTAssertEqual(snapshot.recoveryDiagnostics.filter { $0.itemID == itemID }.count, 1)
        XCTAssertEqual(snapshot.recoveryDiagnostics.first { $0.itemID == itemID }?.outcome, .needsAttention)
        XCTAssertEqual(snapshot.recoveryDiagnostics.first { $0.itemID == itemID }?.detail, "reason=owner conflict")
        XCTAssertEqual(try Data(contentsOf: queued.directoryURL.appendingPathComponent("audio.m4a")), queuedBytes)
        XCTAssertEqual(try Data(contentsOf: attentionURL.appendingPathComponent("audio.m4a")), attentionBytes)
    }

    func testEngineDoesNotDropOrRetryHeldTwin() async throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        let itemID = UUID()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: itemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        )
        let staged = try spool.stage(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        let queued = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        let attentionURL = spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: queued.directoryURL, to: attentionURL)
        let engine = TransferEngine(
            spool: spool,
            transport: TransferTransport(authProvider: { _ in "test-transfer-key" }),
            endpointResolver: TransferCutoverEndpointResolver()
        )

        try await engine.initialize()
        await engine.enableDispatch()
        await engine.drop(itemID: itemID)
        try await engine.retryAttention(itemID: itemID)
        try await engine.retryAttention(source: ObserverAudioTransferSource.omi)

        XCTAssertTrue(FileManager.default.fileExists(atPath: queued.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attentionURL.path))
        let itemSnapshot = await engine.itemSnapshot(itemID: itemID)
        XCTAssertNil(itemSnapshot)
    }
}
