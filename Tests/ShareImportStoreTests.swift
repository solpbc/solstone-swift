// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ShareImportStoreTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        super.tearDown()
    }

    @MainActor
    func testDeliveredHookWritesLedgerReceiptFromManifestMetadataAndSuccessKind() throws {
        let now = Date(timeIntervalSince1970: 1_783_536_000)
        let store = ShareImportStore(cacheRootURL: self.tempDirectory, now: { now })
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let manifest = Self.shareManifest(
            itemID: itemID,
            fields: ShareImportTransferMetadata.Fields(
                basis: "created",
                contentType: "image/jpeg",
                targetJournal: "photos",
                filename: "photo.jpg",
                originApp: "com.example.camera",
                itemTime: "2026-07-09T00:00:00Z",
                bytes: 4,
                requestSource: "file"
            )
        )

        try store.recordDelivered(
            manifest: manifest,
            successKind: .delivered(serverPath: "/imports/photo", serverTimestamp: "2026-07-09T00:00:01Z")
        )

        let entry = try XCTUnwrap(store.loadLedger()[itemID.uuidString.lowercased()])
        XCTAssertEqual(entry.itemID, itemID.uuidString.lowercased())
        XCTAssertEqual(entry.basis, "created")
        XCTAssertEqual(entry.contentType, "image/jpeg")
        XCTAssertEqual(entry.targetJournal, "photos")
        XCTAssertEqual(entry.serverPath, "/imports/photo")
        XCTAssertEqual(entry.serverTimestamp, "2026-07-09T00:00:01Z")
        XCTAssertEqual(entry.deliveredAt, now)
        XCTAssertEqual(entry.filename, "photo.jpg")
        XCTAssertEqual(entry.originApp, "com.example.camera")
        XCTAssertEqual(entry.itemTime, "2026-07-09T00:00:00Z")
        XCTAssertEqual(store.lastDeliveredAt, now)
    }

    @MainActor
    func testLedgerRotationKeepsFiveHundredMostRecentAndReportsDroppedRows() throws {
        let deliveredAt = OSAllocatedUnfairLock<Date>(initialState: Date(timeIntervalSince1970: 0))
        var droppedCounts: [Int] = []
        let store = ShareImportStore(
            cacheRootURL: self.tempDirectory,
            now: { deliveredAt.withLock { $0 } },
            ledgerDropSink: { droppedCounts.append($0) }
        )

        for index in 0...ShareImportStore.ledgerLimit {
            deliveredAt.withLock { $0 = Date(timeIntervalSince1970: TimeInterval(index)) }
            let itemID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            try store.recordDelivered(
                itemID: itemID.uuidString.lowercased(),
                basis: "sent",
                contentType: "text/plain",
                targetJournal: "",
                serverPath: nil,
                serverTimestamp: nil,
                filename: nil,
                originApp: nil,
                itemTime: nil
            )
        }

        let ledger = try store.loadLedger()
        XCTAssertEqual(ledger.count, ShareImportStore.ledgerLimit)
        XCTAssertNil(ledger["00000000-0000-0000-0000-000000000000"])
        XCTAssertNotNil(ledger["00000000-0000-0000-0000-000000000500"])
        XCTAssertEqual(droppedCounts, [1])
    }

    @MainActor
    func testDeliveredHookIsIdempotentByClientItemID() throws {
        let deliveredAt = OSAllocatedUnfairLock<Date>(initialState: Date(timeIntervalSince1970: 1_783_536_000))
        let store = ShareImportStore(
            cacheRootURL: self.tempDirectory,
            now: { deliveredAt.withLock { $0 } }
        )
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let manifest = Self.shareManifest(
            itemID: itemID,
            fields: ShareImportTransferMetadata.Fields(
                basis: "sent",
                contentType: "text/plain",
                targetJournal: "",
                filename: "note.txt",
                originApp: nil,
                itemTime: "2026-07-09T00:00:00Z",
                bytes: 4,
                requestSource: "quick"
            )
        )

        try store.recordDelivered(
            manifest: manifest,
            successKind: .delivered(serverPath: "/imports/one", serverTimestamp: "2026-07-09T00:00:00Z")
        )
        deliveredAt.withLock { $0 = Date(timeIntervalSince1970: 1_783_536_060) }
        try store.recordDelivered(
            manifest: manifest,
            successKind: .delivered(serverPath: "/imports/two", serverTimestamp: "2026-07-09T00:01:00Z")
        )

        let ledger = try store.loadLedger()
        XCTAssertEqual(ledger.count, 1)
        let entry = try XCTUnwrap(ledger[itemID.uuidString.lowercased()])
        XCTAssertEqual(entry.itemID, itemID.uuidString.lowercased())
        XCTAssertEqual(entry.serverPath, "/imports/two")
        XCTAssertEqual(entry.deliveredAt, Date(timeIntervalSince1970: 1_783_536_060))
    }

    private static func shareManifest(
        itemID: UUID,
        fields: ShareImportTransferMetadata.Fields
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: Date(timeIntervalSince1970: 1_783_536_000),
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "file",
                    kind: .file,
                    relativePath: "raw.bin",
                    filename: fields.filename ?? "item.bin",
                    contentType: fields.contentType
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: "/app/import/api/save",
                startPath: "/app/import/api/start",
                requiresAuth: false
            ),
            meta: ShareImportTransferMetadata.meta(fields: fields),
            saveThenStart: TransferSaveThenStartState(phase: .savePending)
        )
    }
}
