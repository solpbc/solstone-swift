// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

@MainActor
private final class RecordingObsidianDelivery: ObsidianNoteDelivering {
    var delivered: [ObsidianOutboxItem] = []
    var beforeEachDelivery: (() throws -> Void)?

    func deliver(item: ObsidianOutboxItem, fileURL: URL) async throws -> TransferEnqueueIfAbsentOutcome {
        try self.beforeEachDelivery?()
        self.delivered.append(item)
        return .enqueued
    }

    func queuedFileCount() async -> Int { 0 }
}

/// How often the Obsidian store, which holds every note's text, is rewritten while notes go out.
@MainActor
final class ObsidianStoreWritesTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        self.root = URL(fileURLWithPath: "/var/tmp/obsidian_writes_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root = self.root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// Counts each replacement of store.json, by file identity, and the bytes it wrote.
    @MainActor
    private final class StoreWrites {
        let url: URL
        private var identity: Int?
        private(set) var count = 0
        private(set) var bytes = 0
        private(set) var largest = 0

        init(_ url: URL) throws {
            self.url = url
            self.identity = try Self.identity(url)
        }

        func observe() throws {
            let current = try Self.identity(url)
            guard current != self.identity else { return }
            self.identity = current
            let size = try Data(contentsOf: self.url).count
            self.count += 1
            self.bytes += size
            self.largest = max(self.largest, size)
        }

        private static func identity(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
        }
    }

    /// A vault holding `noteCount` notes of `textBytes` each, every one changed in its own
    /// already-closed window, so each goes out as its own file.
    private func backlog(noteCount: Int, textBytes: Int) -> ObsidianVaultState {
        let zone = TimeZone(identifier: "America/Denver")!
        var vault = ObsidianVaultState(id: "vault", folderName: "Notes")
        for index in 0..<noteCount {
            let path = "note\(index).md"
            let text = String(repeating: "\(index % 10)", count: textBytes)
            let hash = ObsidianWire.sha256Hex(Data(text.utf8))
            let logicalID = "logical-\(index)"
            vault.table[path] = ObsidianNoteRecord(path: path, documentIdentifier: index, mtimeMs: 0,
                sizeBytes: Int64(textBytes), contentHash: hash, text: text, logicalID: logicalID, representedPath: path)
            let stamp = ObsidianStamp(epochSeconds: 1_700_000_100 + Int64(index) * 300, timeZone: zone)
            vault.pendingChanges.append(ObsidianPendingChange(change: .changed, vault: "Notes", path: path,
                changedAt: stamp, observedAt: stamp, text: text, contentHash: hash,
                logicalKey: logicalID, windowKey: stamp.window.key))
        }
        vault.foundNoteIdentities = Set(vault.table.values.map(\.logicalID))
        vault.foundNotesCount = noteCount
        return vault
    }

    /// Each window costs one store rewrite (its adoption), plus one for packing the backlog.
    /// The journal's acknowledgements, one per window, leave store.json alone.
    func testAcknowledgingABacklogOfWindowsDoesNotRewriteTheStore() async throws {
        let windows = 20
        let store = ObsidianStore(rootURL: self.root)
        store.document.vaults["vault"] = self.backlog(noteCount: windows, textBytes: 8_000)
        store.document.selectedVaultID = "vault"
        store.document.enabled = true
        try store.save()
        let delivery = RecordingObsidianDelivery()
        let engine = ObsidianSourceEngine(store: store, delivery: delivery)
        engine.isPairedProvider = { true }
        let writes = try StoreWrites(store.storeFileURL)
        delivery.beforeEachDelivery = { try writes.observe() }

        await engine.closeDueWindowsAndDeliver()
        try writes.observe()
        XCTAssertEqual(delivery.delivered.count, windows)
        XCTAssertTrue(store.document.vaults["vault"]?.outboxItems.isEmpty ?? false)
        let packedAndAdopted = writes.count

        for item in delivery.delivered {
            try await engine.commitDelivered(manifest: ObsidianTransfer.manifest(for: item),
                successKind: .delivered(serverPath: nil, serverTimestamp: nil))
            try writes.observe()
        }
        XCTAssertEqual(engine.status.deliveredNotesCount, windows)
        XCTAssertEqual(writes.count, packedAndAdopted, "an acknowledgement rewrote store.json")
        XCTAssertLessThanOrEqual(writes.count, windows + 1)
        XCTAssertLessThanOrEqual(writes.bytes, (windows + 1) * writes.largest)

        // The progress outlives a relaunch.
        let reopened = ObsidianSourceEngine(store: ObsidianStore(rootURL: self.root))
        reopened.isPairedProvider = { true }
        XCTAssertEqual(reopened.status.deliveredNotesCount, windows)
    }

    /// A vault whose one note the journal paired now has acknowledged.
    private func vaultWithOneDeliveredNote() async throws -> (ObsidianStore, ObsidianSourceEngine) {
        let store = ObsidianStore(rootURL: self.root)
        var vault = self.backlog(noteCount: 1, textBytes: 10)
        vault.pendingChanges = []
        vault.sameNameChecked = true
        store.document.vaults["vault"] = vault
        store.document.selectedVaultID = "vault"
        try store.save()
        let engine = ObsidianSourceEngine(store: store)
        engine.isPairedProvider = { true }
        let item = ObsidianOutboxItem(itemID: UUID(), filename: "a.jsonl",
            window: ObsidianWindow(day: "20261108", segment: "094000_300"), createdAt: Date(), lineCount: 1,
            byteCount: 10, sha256Hex: "a", timeZoneIdentifier: "America/Denver", offsetSeconds: -25200,
            vaultID: "vault", folderName: "Notes", noteIdentityHashes: ["logical-0"])
        try await engine.commitDelivered(manifest: ObsidianTransfer.manifest(for: item),
            successKind: .delivered(serverPath: nil, serverTimestamp: nil))
        XCTAssertEqual(engine.status.deliveredNotesCount, 1)
        return (store, engine)
    }

    /// The crash this order allows reads progress low: a note is sent again and the journal
    /// answers that it already holds it. It never reads a note as delivered to the journal
    /// paired now that the journal does not have.
    func testANewPairingClearsDeliveredProgressBeforeTheStore() async throws {
        let (store, engine) = try await self.vaultWithOneDeliveredNote()

        // The process dies after the progress is cleared and before store.json is replaced.
        store.testFailNextSave = true
        engine.restartFirstSetup()

        let reopened = ObsidianSourceEngine(store: ObsidianStore(rootURL: self.root))
        reopened.isPairedProvider = { true }
        // store.json is still the earlier pairing's...
        XCTAssertTrue(reopened.isAcceptedForSameName(vaultID: "vault"))
        // ...and the earlier journal's progress does not count for the new one.
        XCTAssertEqual(reopened.status.deliveredNotesCount, 0)
    }

    /// Progress that cannot be cleared keeps store.json as it was, so the store never moves to
    /// the new pairing while the earlier journal's progress stands on disk.
    func testANewPairingThatCannotClearProgressLeavesTheStoreAsItWas() async throws {
        let (store, engine) = try await self.vaultWithOneDeliveredNote()
        let before = try Data(contentsOf: store.storeFileURL)

        store.testFailNextDeliveredSave = true
        engine.restartFirstSetup()
        XCTAssertEqual(try Data(contentsOf: store.storeFileURL), before)
        XCTAssertEqual(engine.status.deliveredNotesCount, 0)
        XCTAssertEqual(engine.status.attention, .privateSaveFault)

        // The next save writes both, the progress first.
        try store.save()
        let reopened = ObsidianSourceEngine(store: ObsidianStore(rootURL: self.root))
        reopened.isPairedProvider = { true }
        XCTAssertFalse(reopened.isAcceptedForSameName(vaultID: "vault"))
        XCTAssertEqual(reopened.status.deliveredNotesCount, 0)
    }

    /// An ack recorded right after the upgrade, before anything else saves the store, survives a
    /// relaunch: the move out of store.json finishes at load.
    func testAnAckRightAfterTheUpgradeSurvivesARelaunch() throws {
        let earlier = #"""
        {"generation":1,"enabled":false,"paused":false,"selectedVaultID":"v","version":1,"vaults":{"v":{
        "id":"v","folderName":"Notes","table":{},"pendingChanges":[],"outboxItems":[],"frozenBaselineHashes":[],
        "unappliedIntakeOps":[],"sameNameChecked":true,"unavailableCount":0,"tooLargeCount":0,
        "deliveredNotes":["n1","n2"],"foundNotesCount":3,
        "foundNoteIdentities":["n1","n2","n3"],"baselineCompleted":true,"intakeSequence":4}}}
        """#
        try Data(earlier.utf8).write(to: self.root.appendingPathComponent("store.json"))
        let store = ObsidianStore(rootURL: self.root)
        XCTAssertFalse(store.hasFault)
        XCTAssertTrue(try store.recordDelivered(["n3"], vaultID: "v"))

        let reopened = ObsidianSourceEngine(store: ObsidianStore(rootURL: self.root))
        reopened.isPairedProvider = { true }
        XCTAssertEqual(reopened.status.deliveredNotesCount, 3)
    }

    /// A store from an earlier build keeps its progress through the move to its own file.
    func testProgressInAnEarlierStoreMovesOutOfStoreJSON() async throws {
        let earlier = #"""
        {"generation":1,"enabled":false,"paused":false,"selectedVaultID":"v","version":1,"vaults":{"v":{
        "id":"v","folderName":"Notes","table":{},"pendingChanges":[],"outboxItems":[],"frozenBaselineHashes":[],
        "unappliedIntakeOps":[],"sameNameChecked":true,"unavailableCount":0,"tooLargeCount":0,
        "deliveredNotes":["n1","n2"],"foundNotesCount":3,
        "foundNoteIdentities":["n1","n2","n3"],"baselineCompleted":true,"intakeSequence":4}}}
        """#
        let storeFile = self.root.appendingPathComponent("store.json")
        try Data(earlier.utf8).write(to: storeFile)
        let store = ObsidianStore(rootURL: self.root)
        XCTAssertFalse(store.hasFault)
        let engine = ObsidianSourceEngine(store: store)
        engine.isPairedProvider = { true }
        XCTAssertEqual(engine.status.deliveredNotesCount, 2)

        try store.save()
        let written = try XCTUnwrap(String(data: Data(contentsOf: storeFile), encoding: .utf8))
        XCTAssertFalse(written.contains("deliveredNotes"))
        let reopened = ObsidianSourceEngine(store: ObsidianStore(rootURL: self.root))
        reopened.isPairedProvider = { true }
        XCTAssertEqual(reopened.status.deliveredNotesCount, 2)
        XCTAssertTrue(reopened.isAcceptedForSameName(vaultID: "v"))
    }
}
