// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SafariBrowserStoreTests: XCTestCase {
    private func rig() throws -> (URL, BrowserContractProjection) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vendor = Bundle.main.resourceURL!.appendingPathComponent("SafariVendor")
        return (root, try BrowserContractProjection(rootURL: vendor))
    }

    private func object(_ frame: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
    }

    private func hello(_ store: SafariBrowserStore, _ projection: BrowserContractProjection) throws -> [String: Any] {
        let frames = try store.exchange(connection: "test", frame: "{\"type\":\"hello\",\"protocol\":1,\"version\":\"0.4.0\",\"brand\":\"safari\",\"inst\":\"test-instance\"}", projection: projection)
        return try self.object(XCTUnwrap(frames.last))
    }

    private func batch(generation: String, id: String = String(repeating: "a", count: 32), text: String = "synthetic marker") throws -> String {
        let value: [String: Any] = ["type": "batch", "destination_generation": generation,
            "inst": "test-instance", "batch_id": id, "queued_at_ms": 1000,
            "records": [["t": "segment_start", "ts": 1000, "ctx": "context", "inst": "test-instance",
                "n": 1, "blocks": [["id": "b", "text": text]], "url": "https://example.test/",
                "site": "example.test", "adapter": "generic", "title": "synthetic"]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func testFreshInstallClosedAndLostReplyRetriesOnlyOnceAcrossReopen() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        XCTAssertEqual(try self.hello(store, projection)["capture"] as? String, "not_paired")
        try store.setConfirmed(true)
        let state = try self.hello(store, projection)
        let frame = try self.batch(generation: XCTUnwrap(state["destination_generation"] as? String))
        let first = try store.exchange(connection: "test", frame: frame, projection: projection)
        XCTAssertEqual(try self.object(first[0])["result"] as? String, "accepted")
        let reopened = try SafariBrowserStore(root: root)
        let retry = try reopened.exchange(connection: "test", frame: frame, projection: projection)
        XCTAssertEqual(try self.object(retry[0])["result"] as? String, "duplicate")
        XCTAssertEqual(try reopened.inventory()["acceptedBatches"] as? Double, 1)
        XCTAssertThrowsError(try reopened.exchange(connection: "test",
            frame: self.batch(generation: XCTUnwrap(state["destination_generation"] as? String), text: "different"), projection: projection))
    }

    func testUnpairAndPauseRefusePriorAuthorityWithoutDroppingHeldPages() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        try store.setConfirmed(true)
        let state = try self.hello(store, projection)
        let generation = try XCTUnwrap(state["destination_generation"] as? String)
        _ = try store.exchange(connection: "test", frame: self.batch(generation: generation), projection: projection)
        try store.setConfirmed(false)
        try store.setConfirmed(true)
        let late = try store.exchange(connection: "test", frame: self.batch(generation: generation,
            id: String(repeating: "b", count: 32)), projection: projection)
        XCTAssertEqual(try self.object(late[0])["result"] as? String, "rejected")
        let current = try self.hello(store, projection)
        try store.setPaused(true)
        let paused = try store.exchange(connection: "test", frame: self.batch(generation: XCTUnwrap(current["destination_generation"] as? String),
            id: String(repeating: "c", count: 32)), projection: projection)
        XCTAssertEqual(try self.object(paused[0])["result"] as? String, "rejected")
        XCTAssertGreaterThan(try XCTUnwrap(store.inventory()["heldBytes"] as? Double), 0)
    }

    func testPendingHandoffSurvivesReopenAndOnlyAdoptsItsSealedBytes() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try SafariBrowserStore(root: root)
        try app.setConfirmed(true)
        let state = try self.hello(app, projection)
        let generation = try XCTUnwrap(state["destination_generation"] as? String)
        _ = try app.exchange(connection: "test", frame: self.batch(generation: generation), projection: projection)
        let sealed = try XCTUnwrap(app.prepareHandoffs().first)
        XCTAssertFalse(try app.admitsDispatch())
        let handler = try SafariBrowserStore(root: root)
        _ = try handler.exchange(connection: "test", frame: self.batch(generation: generation,
            id: String(repeating: "b", count: 32), text: "next period"), projection: projection)
        let resumed = try SafariBrowserStore(root: root)
        XCTAssertEqual(try resumed.prepareHandoffs().first?.payload, sealed.payload)
        try resumed.adopt(id: sealed.id)
        XCTAssertGreaterThan(try XCTUnwrap(resumed.inventory()["heldBytes"] as? Double), 0)
        XCTAssertEqual(try resumed.inventory()["acceptedBatches"] as? Double, 2)
        XCTAssertFalse(try resumed.admitsDispatch()) // the second period remains pending
        let rest = try resumed.prepareHandoffs()
        XCTAssertEqual(rest.count, 1)
        try resumed.adopt(id: XCTUnwrap(rest.first?.id))
        XCTAssertTrue(try resumed.admitsDispatch())
        XCTAssertTrue(try resumed.prepareHandoffs().isEmpty)
    }

    func testFailedCommitNeverAcknowledgesOrLeavesPartialDedupState() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        try store.setConfirmed(true)
        let generation = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        let frame = try self.batch(generation: generation)
        XCTAssertThrowsError(try store.exchange(connection: "test", frame: frame, projection: projection,
            beforeCustodyCommit: { throw SafariBrowserError.storage }))
        let recovered = try SafariBrowserStore(root: root)
        XCTAssertEqual(try recovered.inventory()["acceptedBatches"] as? Double, 0)
        XCTAssertEqual(try recovered.inventory()["heldBytes"] as? Double, 0)
        XCTAssertEqual(try self.object(recovered.exchange(connection: "test", frame: frame, projection: projection)[0])["result"] as? String, "accepted")
    }

    @MainActor func testEngineSpoolCommitBeforeAdoptionRecoversWithoutTwinOrLostPayload() async throws {
        let (root, projection) = try self.rig()
        let spoolRoot = root.appendingPathComponent("engine")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        try store.setConfirmed(true)
        let generation = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        _ = try store.exchange(connection: "test", frame: self.batch(generation: generation), projection: projection)
        // Before spool commit: sealed producer custody alone is enough to recover.
        let period = try XCTUnwrap(store.prepareHandoffs().first)
        XCTAssertFalse(try store.admitsDispatch())
        let first = makeTransferCutoverHarness(rootURL: spoolRoot)
        try await first.engine.initialize()
        // After spool commit, before adoption: both durable copies remain, gated.
        await SafariBrowserDelivery.drain(engine: first.engine, store: store,
            beforeAdoption: { throw SafariBrowserError.storage })
        XCTAssertEqual(try store.prepareHandoffs().first?.payload, period.payload)
        XCTAssertFalse(try store.admitsDispatch())
        let queued = await first.engine.itemSnapshots(sourceKey: "browser")
        XCTAssertEqual(queued.map(\.itemID.uuidString), [period.id])
        let recovered = try SafariBrowserStore(root: root)
        let second = makeTransferCutoverHarness(rootURL: spoolRoot)
        try await second.engine.initialize()
        await SafariBrowserDelivery.drain(engine: second.engine, store: recovered)
        let resumed = await second.engine.itemSnapshots(sourceKey: "browser")
        XCTAssertEqual(resumed.map(\.itemID.uuidString), [period.id])
        XCTAssertTrue(try recovered.admitsDispatch())
        XCTAssertEqual(try recovered.inventory()["heldBytes"] as? Double, 0)
        // The adopted producer stays retired across reopen without depending
        // on a best-effort engine delivery hook.
        XCTAssertTrue(try SafariBrowserStore(root: root).prepareHandoffs().isEmpty)
    }
}
