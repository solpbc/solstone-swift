// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ShareImportTransferSpoolMigratorTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportTransferSpoolMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        super.tearDown()
    }

    @MainActor
    func testMigrationTableLedgerTombstoneQuarantineAndSecondRunNoOp() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroup", isDirectory: true)
        let storeRoot = appGroupRoot.appendingPathComponent("ImportQueue", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent("Transfers", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: storeRoot, now: { Self.baseDate })
        let engine = self.makeEngine(rootURL: transferRoot)
        let diagnosticLog = DiagnosticLog()
        let defaults = try self.makeDefaults()
        try await engine.start()

        let pendingID = Self.uuid(1)
        let startPendingID = Self.uuid(2)
        let transientID = Self.uuid(3)
        let terminalID = Self.uuid(4)
        let unreadableID = Self.uuid(5)
        let tombstoneID = Self.uuid(6)

        try self.writeLegacyItem(root: storeRoot, status: "pending", itemID: pendingID, source: "file", raw: Data("pending".utf8))
        try self.writeLegacyItem(
            root: storeRoot,
            status: "pending",
            itemID: startPendingID,
            source: "file",
            raw: Data("start".utf8),
            savePath: "/imports/start-pending",
            saveTimestamp: "2026-07-09T00:00:00Z",
            saveAction: TransferRecommendedAction.start.rawValue
        )
        try self.writeLegacyItem(
            root: storeRoot,
            status: "failed",
            itemID: transientID,
            source: "quick",
            raw: Data("transient text".utf8),
            failure: ImportFailureRecord(
                classification: .transient,
                reason: "timeout",
                failedAt: Self.baseDate
            )
        )
        try self.writeLegacyItem(
            root: storeRoot,
            status: "failed",
            itemID: terminalID,
            source: "file",
            raw: Data("terminal".utf8),
            failure: ImportFailureRecord(
                classification: .terminal,
                reason: "unsupported",
                failedAt: Self.baseDate
            )
        )
        try self.writeLegacyItem(root: storeRoot, status: "pending", itemID: unreadableID, source: "file", raw: nil)
        try store.recordDelivered(
            itemID: tombstoneID.uuidString.lowercased(),
            basis: "sent",
            contentType: "application/pdf",
            targetJournal: "",
            serverPath: "/imports/delivered",
            serverTimestamp: "2026-07-09T00:00:00Z",
            filename: "document.pdf",
            originApp: nil,
            itemTime: nil
        )
        try self.writeLegacyItem(root: storeRoot, status: "pending", itemID: tombstoneID, source: "file", raw: Data("delivered".utf8))

        await ShareImportTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            store: store,
            transferEngine: engine,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )

        let snapshots = await Dictionary(uniqueKeysWithValues: engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.share).map { ($0.itemID, $0) })
        XCTAssertEqual(snapshots[pendingID]?.manifest.saveThenStart?.phase, .savePending)
        XCTAssertEqual(snapshots[pendingID]?.manifest.payloadParts.first?.kind, .file)
        XCTAssertEqual(snapshots[pendingID]?.manifest.payloadParts.first?.filename, "document.pdf")
        XCTAssertEqual(snapshots[startPendingID]?.manifest.saveThenStart?.phase, .startPending)
        XCTAssertEqual(snapshots[startPendingID]?.manifest.saveThenStart?.savedPath, "/imports/start-pending")
        XCTAssertEqual(snapshots[transientID]?.state, .queued)
        XCTAssertEqual(snapshots[transientID]?.manifest.payloadParts.first?.kind, .text)
        XCTAssertEqual(snapshots[terminalID]?.state, .attention)
        XCTAssertEqual(snapshots[terminalID]?.manifest.attention?.reason, "legacy_terminal_share_import")
        XCTAssertEqual(snapshots[terminalID]?.manifest.attention?.shortDetail, "unsupported")
        XCTAssertNil(snapshots[unreadableID])
        XCTAssertNil(snapshots[tombstoneID])

        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(root: storeRoot, status: "pending", itemID: tombstoneID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(root: storeRoot, status: "pending", itemID: pendingID).path))
        let quarantineEntries = try FileManager.default.contentsOfDirectory(
            at: ShareImportTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantineEntries.filter { $0.lastPathComponent.contains(unreadableID.uuidString.lowercased()) }.count, 1)
        XCTAssertTrue(defaults.bool(forKey: ShareImportTransferSpoolMigrator.flagKey))

        await ShareImportTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            store: store,
            transferEngine: engine,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )
        let migratedCount = await engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.share).count
        XCTAssertEqual(migratedCount, 4)
    }

    @MainActor
    func testEnqueueFailureLeavesOriginalAndKeepsMigrationFlagUnset() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroupFailure", isDirectory: true)
        let storeRoot = appGroupRoot.appendingPathComponent("ImportQueue", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent("Transfers", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: storeRoot, now: { Self.baseDate })
        let spool = TransferSpool(rootURL: transferRoot)
        let collidingID = Self.uuid(20)
        let existingManifest = self.shareManifest(itemID: collidingID, source: "file", kind: .file)
        let staged = try spool.stage(manifest: existingManifest, payloads: ["file": Data("existing".utf8)])
        _ = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)

        let engine = self.makeEngine(spool: spool)
        let diagnosticLog = DiagnosticLog()
        let defaults = try self.makeDefaults()
        try await engine.start()
        try self.writeLegacyItem(root: storeRoot, status: "pending", itemID: collidingID, source: "file", raw: Data("original".utf8))

        await ShareImportTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            store: store,
            transferEngine: engine,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: self.itemDirectory(root: storeRoot, status: "pending", itemID: collidingID).path))
        XCTAssertFalse(defaults.bool(forKey: ShareImportTransferSpoolMigrator.flagKey))
        XCTAssertTrue(diagnosticLog.events.contains { $0.detail?.contains("adoption failed") == true })
    }

    @MainActor
    func testUnreadableLedgerAbortsMigrationWithoutTouchingItemsAndRetriesAfterRepair() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroupCorruptLedger", isDirectory: true)
        let storeRoot = appGroupRoot.appendingPathComponent("ImportQueue", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent("Transfers", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: storeRoot, now: { Self.baseDate })
        let engine = self.makeEngine(rootURL: transferRoot)
        let diagnosticLog = DiagnosticLog()
        let defaults = try self.makeDefaults()
        try await engine.start()

        let itemID = Self.uuid(30)
        try self.writeLegacyItem(root: storeRoot, status: "pending", itemID: itemID, source: "file", raw: Data("delivered".utf8))
        try Data("{".utf8).write(to: storeRoot.appendingPathComponent("ledger.json", isDirectory: false), options: .atomic)

        await ShareImportTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            store: store,
            transferEngine: engine,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: self.itemDirectory(root: storeRoot, status: "pending", itemID: itemID).path))
        let snapshotsAfterAbort = await engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.share)
        XCTAssertTrue(snapshotsAfterAbort.isEmpty)
        XCTAssertTrue(try self.quarantineEntries(appGroupRoot: appGroupRoot).isEmpty)
        XCTAssertFalse(defaults.bool(forKey: ShareImportTransferSpoolMigrator.flagKey))
        XCTAssertTrue(diagnosticLog.events.contains { $0.detail?.contains("ledger unreadable") == true })

        let itemIDString = itemID.uuidString.lowercased()
        try self.writeLedger([itemIDString: self.ledgerEntry(itemID: itemIDString)], root: storeRoot)

        await ShareImportTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            store: store,
            transferEngine: engine,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(root: storeRoot, status: "pending", itemID: itemID).path))
        let snapshotsAfterRepair = await engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.share)
        XCTAssertTrue(snapshotsAfterRepair.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: ShareImportTransferSpoolMigrator.flagKey))
    }

    @MainActor
    func testAbsentLedgerMigratesNormally() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroupAbsentLedger", isDirectory: true)
        let storeRoot = appGroupRoot.appendingPathComponent("ImportQueue", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent("Transfers", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: storeRoot, now: { Self.baseDate })
        let engine = self.makeEngine(rootURL: transferRoot)
        let defaults = try self.makeDefaults()
        try await engine.start()

        let itemID = Self.uuid(31)
        try self.writeLegacyItem(root: storeRoot, status: "pending", itemID: itemID, source: "file", raw: Data("pending".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("ledger.json", isDirectory: false).path))

        await ShareImportTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            store: store,
            transferEngine: engine,
            diagnosticLog: nil,
            defaults: defaults
        )

        let snapshots = await engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.share)
        XCTAssertEqual(snapshots.map(\.itemID), [itemID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.itemDirectory(root: storeRoot, status: "pending", itemID: itemID).path))
        XCTAssertTrue(defaults.bool(forKey: ShareImportTransferSpoolMigrator.flagKey))
    }

    @MainActor
    private func makeEngine(rootURL: URL) -> TransferEngine {
        self.makeEngine(spool: TransferSpool(rootURL: rootURL))
    }

    @MainActor
    private func makeEngine(spool: TransferSpool) -> TransferEngine {
        TransferEngine(
            spool: spool,
            transport: TransferTransport(
                sessionConfiguration: makeTransferTestURLSessionConfiguration(),
                authProvider: { _ in "test-transfer-key" }
            ),
            endpointResolver: TransferEndpointResolverStub(.unavailable("held")),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate),
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
    }

    private func writeLegacyItem(
        root: URL,
        status: String,
        itemID: UUID,
        source: String,
        raw: Data?,
        savePath: String? = nil,
        saveTimestamp: String = "2026-07-09T00:00:00Z",
        saveAction: String = TransferRecommendedAction.start.rawValue,
        saveSource: String? = nil,
        failure: ImportFailureRecord? = nil
    ) throws {
        let itemIDString = itemID.uuidString.lowercased()
        let directory = self.itemDirectory(root: root, status: status, itemID: itemID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let raw {
            try raw.write(to: directory.appendingPathComponent("raw.bin", isDirectory: false), options: .atomic)
        }
        let note = ShareImportStore.FrozenNote(
            source: source,
            originApp: "com.example.share",
            contentType: source == "quick" ? "text/plain" : "application/pdf",
            filename: source == "quick" ? "note.txt" : "document.pdf",
            bytes: Int64(raw?.count ?? 0),
            basis: "file",
            itemTime: "2026-07-09T00:00:00Z",
            targetJournal: "",
            itemID: itemIDString
        )
        try ShareImportStore.orderedNoteData(note)
            .write(to: directory.appendingPathComponent("item.json", isDirectory: false), options: .atomic)
        let requestJSON: [String: Any] = [
            "content_type": source == "quick" ? "text/plain" : "application/pdf",
            "filename": source == "quick" ? "text.txt" : "document.pdf",
            "source": source,
        ]
        try JSONSerialization.data(withJSONObject: requestJSON, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("request.json", isDirectory: false), options: .atomic)
        if let savePath {
            var saveJSON: [String: Any] = [
                "path": savePath,
                "recommended_action": saveAction,
                "timestamp": saveTimestamp,
            ]
            if let saveSource {
                saveJSON["source"] = saveSource
            }
            try JSONSerialization.data(withJSONObject: saveJSON, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("save.json", isDirectory: false), options: .atomic)
        }
        if let failure {
            try self.encoder.encode(failure)
                .write(to: directory.appendingPathComponent("failure.json", isDirectory: false), options: .atomic)
        }
    }

    private func itemDirectory(root: URL, status: String, itemID: UUID) -> URL {
        root.appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID.uuidString.lowercased(), isDirectory: true)
    }

    @MainActor
    private func quarantineEntries(appGroupRoot: URL) throws -> [URL] {
        let root = ShareImportTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    private func writeLedger(_ ledger: [String: ShareImportStore.LedgerEntry], root: URL) throws {
        try self.encoder.encode(ledger)
            .write(to: root.appendingPathComponent("ledger.json", isDirectory: false), options: .atomic)
    }

    private func ledgerEntry(itemID: String) -> ShareImportStore.LedgerEntry {
        ShareImportStore.LedgerEntry(
            itemID: itemID,
            basis: "sent",
            contentType: "application/pdf",
            targetJournal: "",
            serverPath: "/imports/delivered",
            serverTimestamp: "2026-07-09T00:00:00Z",
            deliveredAt: Self.baseDate,
            filename: "document.pdf",
            originApp: nil,
            itemTime: nil
        )
    }

    private func shareManifest(itemID: UUID, source: String, kind: TransferPayloadKind) -> TransferManifest {
        let partID = kind == .text ? "text" : "file"
        return TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: Self.baseDate,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: partID,
                    kind: kind,
                    relativePath: "raw.bin",
                    filename: source == "quick" ? "text.txt" : "document.pdf",
                    contentType: source == "quick" ? "text/plain" : "application/pdf"
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: ImporterServerURL.savePath,
                startPath: ImporterServerURL.startPath,
                requiresAuth: false
            ),
            meta: ShareImportTransferMetadata.meta(fields: ShareImportTransferMetadata.Fields(
                basis: "file",
                contentType: source == "quick" ? "text/plain" : "application/pdf",
                targetJournal: "",
                filename: source == "quick" ? "note.txt" : "document.pdf",
                originApp: "com.example.share",
                itemTime: "2026-07-09T00:00:00Z",
                bytes: nil,
                requestSource: source
            )),
            saveThenStart: TransferSaveThenStartState(phase: .savePending)
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ShareImportTransferSpoolMigratorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_783_536_000)

    private static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
