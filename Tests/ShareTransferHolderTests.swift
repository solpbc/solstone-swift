// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class ShareTransferHolderTests: XCTestCase {
    func testNoDoubleCountAcrossStoreEngineAndLedgerStates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareTransferHolderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000060001")!
        let store = ShareImportStore(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            now: { Self.baseDate }
        )
        _ = try ShareImportLegacyTestSupport.writeLegacyItem(
            root: store.cacheRootURL,
            itemID: itemID,
            source: "quick",
            raw: Data("holder share".utf8),
            contentType: "text/plain",
            requestFilename: "text.txt",
            originalFilename: "note.txt"
        )
        let transfer = makeTransferCutoverHarness(
            rootURL: root.appendingPathComponent("Transfers", isDirectory: true),
            endpointResolver: TransferEndpointResolverStub(.unavailable("waiting")),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        let holder = ShareTransferHolder(transferEngine: transfer.engine, mirror: transfer.mirror, store: store)
        try await transfer.engine.start()

        store.refreshFromDisk()
        XCTAssertEqual(holder.pendingCount, 1)
        let storeItemIDs = try self.itemIDs(await holder.onThisPhoneSourceSnapshot())
        XCTAssertEqual(storeItemIDs, [itemID.uuidString.lowercased()])

        let unresolved = await store.adoptToTransfer(
            engine: transfer.engine,
            diagnosticLog: nil,
            quarantineRootURL: root.appendingPathComponent("TransferQuarantine", isDirectory: true)
        )
        XCTAssertEqual(unresolved, 0)
        transfer.mirror.apply(snapshot: await transfer.engine.snapshot())
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(holder.pendingCount, 1)
        let engineItemIDs = try self.itemIDs(await holder.onThisPhoneSourceSnapshot())
        XCTAssertEqual(engineItemIDs, [itemID.uuidString.lowercased()])

        await transfer.engine.drop(itemID: itemID)
        try store.recordDelivered(
            itemID: itemID.uuidString.lowercased(),
            basis: "file",
            contentType: "text/plain",
            targetJournal: "",
            serverPath: "/imports/share",
            serverTimestamp: "2026-07-09T00:00:00Z",
            filename: "note.txt",
            originApp: nil,
            itemTime: "2026-07-09T00:00:00Z"
        )
        transfer.mirror.apply(snapshot: await transfer.engine.snapshot())
        XCTAssertEqual(holder.pendingCount, 0)
        XCTAssertEqual(holder.failedCount, 0)
        let deliveredItems = try self.items(await holder.onThisPhoneSourceSnapshot())
        XCTAssertEqual(deliveredItems.map(\.id), [itemID.uuidString.lowercased()])
        XCTAssertEqual(deliveredItems.first?.sendState, .inYourJournal)
    }

    private func itemIDs(_ result: OnThisPhoneSourceResult) throws -> [String] {
        try self.items(result).map(\.id)
    }

    private func items(_ result: OnThisPhoneSourceResult) throws -> [OnThisPhoneItem] {
        guard case .loaded(let items) = result else {
            XCTFail("Expected loaded share snapshot")
            return []
        }
        return items
    }

    nonisolated private static let baseDate = Date(timeIntervalSince1970: 1_783_536_000)
}
