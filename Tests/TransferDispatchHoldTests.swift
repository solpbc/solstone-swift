// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated private struct DispatchHoldAvailableEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

@MainActor
final class TransferDispatchHoldTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferDispatchHoldTests-\(UUID().uuidString)", isDirectory: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    func testHeldItemStaysVisibleAndCannotDispatchOrDropWhileUnrelatedItemSends() async throws {
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let clock = FakeTransferClock(wall: Date())
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: DispatchHoldAvailableEndpointResolver(),
            clock: clock,
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )
        try await harness.engine.initialize()
        let sessionID = UUID()
        let heldID = UUID()
        let heldAttentionID = UUID()
        let otherID = UUID()
        let otherAttentionID = UUID()
        let backedOffID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let heldManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: heldID, sidecar: sidecar)
        let heldAttentionManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: heldAttentionID, sidecar: sidecar)
        let otherManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: otherID, sidecar: sidecar)
        let otherAttentionManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: otherAttentionID, sidecar: sidecar)
        var backedOffManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: backedOffID, sidecar: sidecar)
        backedOffManifest = backedOffManifest.replacingNextAttemptAt(clock.wallNow().addingTimeInterval(1))
        _ = try await harness.engine.enqueue(manifest: heldManifest, payloads: ["audio": Data("held".utf8)])
        _ = try await harness.engine.enqueueAttention(
            manifest: heldAttentionManifest,
            payloadFileURLs: try self.payloadFileURLs(for: "held attention"),
            reason: "test",
            detail: "test"
        )
        _ = try await harness.engine.enqueue(manifest: backedOffManifest, payloads: ["audio": Data("backed off".utf8)])
        _ = try await harness.engine.enqueue(manifest: otherManifest, payloads: ["audio": Data("other".utf8)])
        _ = try await harness.engine.enqueueAttention(
            manifest: otherAttentionManifest,
            payloadFileURLs: try self.payloadFileURLs(for: "other attention"),
            reason: "test",
            detail: "test"
        )
        await harness.engine.hold(itemID: heldID)
        await harness.engine.hold(itemID: heldAttentionID)

        let heldBeforeDispatch = await harness.engine.itemSnapshot(itemID: heldID)
        let heldPayloadBeforeDispatch = await harness.engine.payloadFileURL(itemID: heldID, partID: "audio")
        XCTAssertNotNil(heldBeforeDispatch)
        XCTAssertNotNil(heldPayloadBeforeDispatch)
        let heldAttentionBeforeDispatch = await harness.engine.itemSnapshot(itemID: heldAttentionID)
        let heldAttentionPayloadBeforeDispatch = await harness.engine.payloadFileURL(itemID: heldAttentionID, partID: "audio")
        XCTAssertNotNil(heldAttentionBeforeDispatch)
        XCTAssertNotNil(heldAttentionPayloadBeforeDispatch)
        await harness.engine.endpointAvailabilityChanged()
        await harness.engine.kick()
        await harness.engine.setPacingMode(.finishSyncing)
        await harness.engine.pause()
        await harness.engine.resume()
        try await harness.engine.retryAttention(itemID: heldID)
        try await harness.engine.retryAttention(itemID: heldAttentionID)
        try await harness.engine.retryAttention(source: ObserverAudioTransferSource.omi)
        await harness.engine.drop(itemID: heldID)
        await harness.engine.drop(itemID: heldAttentionID)

        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(
            Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))),
            Set([otherID, otherAttentionID])
        )
        let heldAfterDispatch = await harness.engine.itemSnapshot(itemID: heldID)
        let heldPayloadAfterDispatch = await harness.engine.payloadFileURL(itemID: heldID, partID: "audio")
        XCTAssertNotNil(heldAfterDispatch)
        XCTAssertNotNil(heldPayloadAfterDispatch)
        let heldAttentionAfterDispatch = await harness.engine.itemSnapshot(itemID: heldAttentionID)
        let heldAttentionPayloadAfterDispatch = await harness.engine.payloadFileURL(itemID: heldAttentionID, partID: "audio")
        XCTAssertNotNil(heldAttentionAfterDispatch)
        XCTAssertNotNil(heldAttentionPayloadAfterDispatch)
        clock.advanceWall(by: 2)
        clock.resumeSleeps()
        try await transferTestWaitFor("retry timer dispatch") {
            TransferURLProtocol.requests.count == 3
        }
        XCTAssertEqual(transferTestBoundaryItemID(from: TransferURLProtocol.requests[2]), backedOffID)
        let heldAfterRetryTimer = await harness.engine.itemSnapshot(itemID: heldID)
        let heldAttentionAfterRetryTimer = await harness.engine.itemSnapshot(itemID: heldAttentionID)
        XCTAssertNotNil(heldAfterRetryTimer)
        XCTAssertNotNil(heldAttentionAfterRetryTimer)
    }

    func testHoldDiagnosticIsBoundedAndPayloadFree() async throws {
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )
        try await harness.engine.initialize()
        let sessionID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: firstID, sidecar: sidecar),
            payloads: ["audio": Data("first".utf8)]
        )
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: secondID, sidecar: sidecar),
            payloads: ["audio": Data("second".utf8)]
        )

        await harness.engine.hold(itemID: firstID)
        await harness.engine.hold(itemID: firstID)
        await harness.engine.hold(itemID: secondID)

        let held = events.withLock { values in values.filter { $0.outcome == .held && $0.shortDetail == "reason=duplicate cleanup" } }
        XCTAssertEqual(held.map(\.itemID), [firstID, secondID])
        XCTAssertTrue(held.allSatisfy { !$0.shortDetail.contains("/") })
    }

    private func payloadFileURLs(for contents: String) throws -> [String: URL] {
        let url = self.rootURL.appendingPathComponent("payload-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
        return ["audio": url]
    }
}
