// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SafariBrowserStoreTests: XCTestCase {
    private func rig() throws -> (URL, BrowserContractProjection) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vendor = Bundle.main.resourceURL!.appendingPathComponent("browser-contract")
        return (root, try BrowserContractProjection(rootURL: vendor))
    }

    private func object(_ frame: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
    }

    private func hello(_ store: SafariBrowserStore, _ projection: BrowserContractProjection) throws -> [String: Any] {
        let frames = try store.exchange(connection: "test", frame: "{\"type\":\"hello\",\"protocol\":1,\"version\":\"0.4.0\",\"brand\":\"safari\",\"inst\":\"test-instance\"}", projection: projection)
        return try self.object(XCTUnwrap(frames.last))
    }

    private func batch(generation: String, id: String = String(repeating: "a", count: 32), text: String = "synthetic marker",
                       delta: Bool = false) throws -> String {
        let record: [String: Any] = delta
            ? ["t": "delta", "ts": 2000, "ctx": "context", "inst": "test-instance", "site": "example.test",
               "op": "add", "block": ["id": "c", "text": text]]
            : ["t": "segment_start", "ts": 1000, "ctx": "context", "inst": "test-instance",
               "n": 1, "blocks": [["id": "b", "text": text]], "url": "https://example.test/",
               "site": "example.test", "adapter": "generic", "title": "synthetic"]
        let value: [String: Any] = ["type": "batch", "destination_generation": generation,
            "inst": "test-instance", "batch_id": id, "queued_at_ms": 1000, "records": [record]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func id(_ c: Character) -> String { String(repeating: c, count: 32) }

    private func state(_ frames: [String]) throws -> [String: Any] { try self.object(XCTUnwrap(frames.last)) }

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

    func testAPeriodSealsAtItsAgeAndADeltaAfterwardAsksForASnapshot() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        try store.setConfirmed(true)
        let generation = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        let t0 = Date().timeIntervalSince1970
        let first = try store.exchange(connection: "test", frame: self.batch(generation: generation), projection: projection, now: t0)
        XCTAssertEqual(try self.object(first[0])["result"] as? String, "accepted")
        let sameContext = try store.exchange(connection: "test", frame: self.batch(generation: generation, id: self.id("b"), delta: true),
            projection: projection, now: t0 + 10)
        XCTAssertEqual(try self.object(sameContext[0])["result"] as? String, "accepted")
        let later = t0 + SafariBrowserStore.periodSeconds + 1
        let afterSeal = try store.exchange(connection: "test", frame: self.batch(generation: generation, id: self.id("c"), delta: true),
            projection: projection, now: later)
        XCTAssertEqual(try self.object(afterSeal[0])["reason"] as? String, "snapshot_required")
        let snapshot = try store.exchange(connection: "test", frame: self.batch(generation: generation, id: self.id("d")),
            projection: projection, now: later + 1)
        XCTAssertEqual(try self.object(snapshot[0])["result"] as? String, "accepted")
        let periods = try store.prepareHandoffs(now: later + 2)
        XCTAssertEqual(periods.count, 2)
        // The first segment ends at its last page, not when the app drained it.
        XCTAssertEqual(try XCTUnwrap(periods.first).ended, t0 + 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(periods.last).started, later + 1, accuracy: 0.001)
    }

    func testDedupIdentitiesLastTheContractWindowAndNoLonger() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        try store.setConfirmed(true)
        let generation = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        let t0 = Date().timeIntervalSince1970
        let frame = try self.batch(generation: generation)
        _ = try store.exchange(connection: "test", frame: frame, projection: projection, now: t0)
        let window = Double(projection.policy.acceptedRetentionMs) / 1000
        let retry = try store.exchange(connection: "test", frame: frame, projection: projection, now: t0 + window - 1)
        XCTAssertEqual(try self.object(retry[0])["result"] as? String, "duplicate")
        _ = try store.exchange(connection: "test", frame: nil, projection: projection, now: t0 + window + 1)
        XCTAssertEqual(try store.inventory()["acceptedBatches"] as? Double, 0)
    }

    func testDeliveryReadsKeptLocallyOnlyWhileThePhoneStillHoldsPages() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        try store.setConfirmed(true)
        XCTAssertEqual(try self.hello(store, projection)["delivery"] as? String, "idle")
        let generation = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        let accepted = try store.exchange(connection: "test", frame: self.batch(generation: generation), projection: projection)
        XCTAssertEqual(try self.state(accepted)["delivery"] as? String, "kept_locally")
        let period = try XCTUnwrap(store.prepareHandoffs().first)
        try store.adopt(id: period.id)
        try store.setQueuedBytes(period.payload.count)
        XCTAssertEqual(try self.state(store.exchange(connection: "test", frame: nil, projection: projection))["delivery"] as? String, "kept_locally")
        try store.setQueuedBytes(0)
        XCTAssertEqual(try self.state(store.exchange(connection: "test", frame: nil, projection: projection))["delivery"] as? String, "idle")
    }

    func testAFullStoreRefusesNewPagesSaysSoAndReopensAfterTheAppTakesThem() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root, quota: 4096)
        try store.setConfirmed(true)
        let generation = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        let big = String(repeating: "x", count: 2100)
        let t0 = Date().timeIntervalSince1970
        _ = try store.exchange(connection: "test", frame: self.batch(generation: generation, text: big), projection: projection, now: t0)
        let refused = try store.exchange(connection: "test", frame: self.batch(generation: generation, id: self.id("b"), text: big),
            projection: projection, now: t0 + 1)
        XCTAssertEqual(try self.object(refused[0])["result"] as? String, "rejected")
        let full = try self.state(refused)
        XCTAssertEqual(full["capture"] as? String, "intake_off")
        XCTAssertEqual((full["custody"] as? [String: Any])?["full"] as? Bool, true)
        try store.adopt(id: XCTUnwrap(store.prepareHandoffs().first).id)
        let reopened = try self.state(store.exchange(connection: "test", frame: nil, projection: projection, now: t0 + 2))
        XCTAssertEqual(reopened["capture"] as? String, "permitted")
    }

    func testHeldPagesWaitThroughUnpairAndFollowTheNextConfirmation() throws {
        let (root, projection) = try self.rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SafariBrowserStore(root: root)
        try store.setConfirmed(true)
        let first = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        _ = try store.exchange(connection: "test", frame: self.batch(generation: first), projection: projection)
        try store.setConfirmed(false)
        XCTAssertEqual(try self.hello(store, projection)["capture"] as? String, "not_paired")
        let held = try XCTUnwrap(store.inventory()["heldBytes"] as? Double)
        XCTAssertGreaterThan(held, 0)
        try store.setConfirmed(true)
        let second = try XCTUnwrap(self.hello(store, projection)["destination_generation"] as? String)
        XCTAssertNotEqual(first, second)
        // Nothing about the held page names a journal: it seals and hands off as before.
        let periods = try store.prepareHandoffs()
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(Double(try XCTUnwrap(periods.first).payload.count), held)
    }
}
