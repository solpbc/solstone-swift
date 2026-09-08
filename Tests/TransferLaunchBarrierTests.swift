// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated private struct AvailableTransferEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

final class TransferLaunchBarrierTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferLaunchBarrierTests-\(UUID().uuidString)", isDirectory: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    @MainActor func testInitializeDefersDispatchUntilEnable() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        let manifest = makeTransferTestWatchManifest(
            itemID: UUID(),
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        )

        try await harness.engine.initialize()
        try await harness.engine.initialize()
        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        await harness.engine.enableDispatch()
        try await transferTestWaitFor("single dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        await harness.engine.enableDispatch()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)
    }

    @MainActor func testConstructionDefersEveryDispatchTriggerUntilInitializeAndEnable() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        let manifest = makeTransferTestWatchManifest(
            itemID: UUID(),
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        )

        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        await harness.engine.endpointAvailabilityChanged()
        await harness.engine.kick()
        await harness.engine.setPacingMode(.finishSyncing)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("construction barrier dispatch") {
            TransferURLProtocol.requests.count == 1
        }
    }

    @MainActor func testRestoredUnknownSourceDoesNotBlockSupportedDispatch() async throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        let unknownQueuedID = UUID()
        let unknownAttentionID = UUID()
        let supportedID = UUID()
        for itemID in [unknownQueuedID, unknownAttentionID, supportedID] {
            var manifest = makeTransferTestWatchManifest(
                itemID: itemID,
                sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
            )
            if itemID != supportedID {
                manifest.source = "retired-source"
            }
            let staged = try spool.stage(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
            let queued = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
            if itemID == unknownAttentionID {
                _ = try spool.moveQueuedItemToAttention(queued, reason: "held", detail: "held", now: Date())
            }
        }
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        try await harness.engine.initialize()
        let restored = await harness.engine.itemSnapshot(itemID: unknownAttentionID)
        XCTAssertEqual(restored?.manifest.diskState, .attention)
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("supported and unknown queued items delivered") {
            await harness.engine.snapshot().counters.deliveredCount == 2
        }
        XCTAssertEqual(Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))),
                       Set([unknownQueuedID, supportedID]))
        let held = await harness.engine.itemSnapshot(itemID: unknownAttentionID)
        XCTAssertEqual(held?.manifest.diskState, .attention)
        XCTAssertEqual(held?.manifest.source, "retired-source")
    }

}
