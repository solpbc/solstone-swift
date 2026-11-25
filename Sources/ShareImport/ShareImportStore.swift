// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import UniformTypeIdentifiers

private let shareImportLog = Logger(subsystem: "app.solstone.swift", category: "share-import")

nonisolated enum ImportFailureClassification: String, Codable, Sendable {
    case terminal
    case transient
}

nonisolated struct ImportFailureRecord: Codable, Sendable {
    let classification: ImportFailureClassification
    let reason: String
    let failedAt: Date
}

nonisolated enum ShareImportID {
    /// Validates a journal import timestamp ID against strict ASCII `^[0-9]{8}_[0-9]{6}$`.
    /// Never accepts Unicode digits, slashes, dots, whitespace, or query/fragment characters.
    static func validated(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bytes = Array(raw.utf8)
        guard bytes.count == 15, bytes[8] == UInt8(ascii: "_") else { return nil }
        let zero = UInt8(ascii: "0")
        let nine = UInt8(ascii: "9")
        for index in 0..<8 where bytes[index] < zero || bytes[index] > nine {
            return nil
        }
        for index in 9..<15 where bytes[index] < zero || bytes[index] > nine {
            return nil
        }
        return raw
    }

    static func detailPath(for raw: String?) -> String? {
        self.validated(raw).map { "/app/import/\($0)" }
    }

    /// True ONLY for explicit confirmation-required `409 import_preview_required` kinds.
    static func isConfirmationRequiredKind(_ kind: String?) -> Bool {
        guard let kind, !kind.isEmpty else { return false }
        if kind == "body_confirmation_required" || kind == "confirmation_required" {
            return true
        }
        return kind.hasSuffix("_confirmation_required") && kind.count > "_confirmation_required".count
    }
}

/// Lightweight 24-hour delivered receipt persisted for the inline `recent` section on `ImportView`.
/// Separate from `ledger.json` (which retains the high-cap delivery lookup).
nonisolated struct ImportRecentReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let filename: String
    let importID: String?
    let instanceID: String
    let deliveredAtEpochMs: Int64

    var deliveredAt: Date {
        Date(timeIntervalSince1970: Double(self.deliveredAtEpochMs) / 1000.0)
    }

    var validatedImportID: String? {
        ShareImportID.validated(self.importID)
    }

    var journalDetailPath: String? {
        ShareImportID.detailPath(for: self.importID)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case importID = "import_id"
        case instanceID = "instance_id"
        case deliveredAtEpochMs = "delivered_at_epoch_ms"
    }
}

@MainActor
@Observable
final class ShareImportStore {
    nonisolated static let ledgerLimit = 500
    nonisolated static let recentReceiptCap = 5
    nonisolated static let recentReceiptTTL: TimeInterval = 24 * 60 * 60

    var pendingCount = 0
    var failedCount = 0
    var lastDeliveredAt: Date?
    var lastError: String?
    private(set) var storedRecentReceipts: [ImportRecentReceipt] = []

    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored let payloadIO: any ShareImportPayloadIO
    @ObservationIgnored let cacheRootURL: URL
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private let ledgerDropSink: @MainActor @Sendable (Int) -> Void
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored let decoder = JSONDecoder()
    /// Nil in tests and when the app group is unavailable. A skipped count does not fail the enqueue.
    @ObservationIgnored var intake: SourceIntakeStore? = nil

    init(
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        payloadIO: (any ShareImportPayloadIO)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        ledgerDropSink: @escaping @MainActor @Sendable (Int) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.payloadIO = payloadIO ?? FoundationShareImportPayloadIO(fileManager: fileManager)
        self.cacheRootURL = cacheRootURL ?? Self.defaultCacheRootURL(fileManager: fileManager)
        self.now = now
        self.ledgerDropSink = ledgerDropSink
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder.dateDecodingStrategy = .iso8601
        try? self.ensureRootDirectories()
        self.refreshCounts()
        self.lastDeliveredAt = (try? self.loadLedger().values.map(\.deliveredAt).max()) ?? nil
        self.storedRecentReceipts = self.loadAndPruneRecentReceipts(now: self.now(), persistIfChanged: false)
    }

    func beginEnqueue() throws -> ShareImportEnqueueHandle {
        try self.ensureRootDirectories()
        let itemID = UUID()
        let itemIDString = Self.itemIDString(itemID)
        let stagingDirectory = self.stagingItemDirectoryURL(itemID: itemIDString)
        try self.fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        return ShareImportEnqueueHandle(
            itemID: itemID,
            itemIDString: itemIDString,
            stagingDirectoryURL: stagingDirectory,
            stagingRawURL: self.rawURL(itemID: itemIDString, status: .staging)
        )
    }

    func makeFileSink(
        handle: ShareImportEnqueueHandle,
        operation: ShareImportLandingOperation,
        inboundContentType: String,
        suggestedFilename: String?
    ) -> any ShareFileSink {
        ShareImportFileSink(
            stagingRawURL: handle.stagingRawURL,
            volumeURL: self.cacheRootURL,
            payloadIO: self.payloadIO,
            operation: operation,
            inboundContentType: inboundContentType,
            suggestedFilename: suggestedFilename,
            now: self.now
        )
    }

    func commitEnqueue(
        handle: ShareImportEnqueueHandle,
        delivery: ShareFileDelivery,
        source: String,
        targetJournal: String,
        originApp: String?,
        handoff: ShareImportHandoff?
    ) throws -> UUID {
        do {
            let rawInfo = Self.rawFileInfo(for: delivery.contentType)
            let note = FrozenNote(
                source: source,
                originApp: originApp,
                contentType: delivery.contentType,
                filename: delivery.filename,
                bytes: delivery.byteCount,
                basis: delivery.basis,
                itemTime: Self.iso8601String(for: delivery.itemTime),
                targetJournal: targetJournal,
                itemID: handle.itemIDString,
                capturedAt: delivery.capturedAt,
                importArea: handoff?.area,
                importContext: handoff?.context
            )
            let requestFilename = ShareImportOrigin.requestFilename(originApp: originApp, ownName: delivery.filename, standIn: rawInfo.filename)
            let descriptor = RequestDescriptor(source: source, filename: requestFilename, contentType: rawInfo.mimeType)
            try self.writeData(Self.orderedNoteData(note), to: self.noteURL(itemID: handle.itemIDString, status: .staging))
            try self.writeData(self.encoder.encode(descriptor), to: self.descriptorURL(itemID: handle.itemIDString, status: .staging))
            try self.fileManager.moveItem(
                at: handle.stagingDirectoryURL,
                to: self.pendingItemDirectoryURL(itemID: handle.itemIDString)
            )
            self.intake?.recordImport(itemID: handle.itemIDString, now: self.now())
            shareImportLog.info("share import item staged \(handle.itemIDString, privacy: .public)")
            self.refreshCounts()
            return handle.itemID
        } catch {
            try? self.fileManager.removeItem(at: handle.stagingDirectoryURL)
            let detail = String(describing: error)
            shareImportLog.error("failed to stage share import \(handle.itemIDString, privacy: .public): \(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
            throw error
        }
    }

    func abortEnqueue(_ handle: ShareImportEnqueueHandle) {
        try? self.fileManager.removeItem(at: handle.stagingDirectoryURL)
        self.refreshCounts()
    }

    func refreshFromDisk() {
        do {
            try self.ensureRootDirectories()
            let ledger = try self.loadLedger()
            for status in [ItemStatus.pending, .failed] {
                let directories = try self.itemDirectories(status: status)
                for directory in directories {
                    let itemID = directory.lastPathComponent
                    if ledger[itemID] != nil {
                        try? self.fileManager.removeItem(at: directory)
                    }
                }
            }
            self.lastDeliveredAt = ledger.values.map(\.deliveredAt).max()
        } catch {
            let detail = String(describing: error)
            shareImportLog.error("share import refresh failed: \(detail, privacy: .public)")
            self.lastError = detail
        }
        self.refreshCounts()
    }

    func dropItem(itemID: UUID) {
        let itemIDString = Self.itemIDString(itemID)
        try? self.fileManager.removeItem(at: self.pendingItemDirectoryURL(itemID: itemIDString))
        try? self.fileManager.removeItem(at: self.failedItemDirectoryURL(itemID: itemIDString))
        if var ledger = try? self.loadLedger(), ledger.removeValue(forKey: itemIDString) != nil {
            try? self.saveLedger(ledger)
            self.lastDeliveredAt = ledger.values.map(\.deliveredAt).max()
        }
        self.removeRecentReceipt(id: itemIDString)
        self.refreshCounts()
        shareImportLog.info("share import item dropped \(itemIDString, privacy: .public)")
    }

    func onThisPhoneSourceSnapshot() -> OnThisPhoneSourceResult {
        let interval = DrainSignpost.begin(.sourceSnapshotScan, source: .share)
        let ledger: [String: LedgerEntry]
        do {
            ledger = try self.loadLedger()
        } catch {
            DrainSignpost.end(interval, source: .share, fields: DrainFields(status: "failed", error: DrainErrorCategory.classify(error), items: 0))
            return .failed
        }

        var items: [OnThisPhoneItem] = []
        for directory in (try? self.itemDirectories(status: .pending)) ?? [] {
            let itemID = directory.lastPathComponent
            guard ledger[itemID] == nil else { continue }
            items.append(self.localOnThisPhoneItem(itemID: itemID, status: .pending, location: .pending))
        }
        for directory in (try? self.itemDirectories(status: .failed)) ?? [] {
            let itemID = directory.lastPathComponent
            guard ledger[itemID] == nil else { continue }
            items.append(self.localOnThisPhoneItem(itemID: itemID, status: .failed, location: .failed))
        }
        for (itemID, entry) in ledger {
            items.append(self.deliveredOnThisPhoneItem(itemID: itemID, entry: entry))
        }

        let sortedItems = OnThisPhoneItemSort.newestFirst(items)
        DrainSignpost.end(interval, source: .share, fields: DrainFields(status: "loaded", error: Optional<DrainErrorCategory>.none, items: sortedItems.count))
        return .loaded(items: sortedItems)
    }

    func recordDelivered(
        itemID: String,
        basis: String,
        contentType: String,
        targetJournal: String,
        serverPath: String?,
        serverTimestamp: String?,
        filename: String?,
        originApp: String?,
        itemTime: String?,
        instanceID: String? = nil,
        recordReceipt: Bool = true
    ) throws {
        var ledger = try self.loadLedger()
        let deliveredAt = self.now()
        let normalizedInstanceID = instanceID.flatMap { $0.isEmpty ? nil : $0 }
        ledger[itemID] = LedgerEntry(
            itemID: itemID,
            basis: basis,
            contentType: contentType,
            targetJournal: targetJournal,
            serverPath: serverPath,
            serverTimestamp: serverTimestamp,
            deliveredAt: deliveredAt,
            filename: filename,
            originApp: originApp,
            itemTime: itemTime,
            instanceID: normalizedInstanceID
        )
        ledger = self.rotatedLedger(ledger)
        try self.saveLedger(ledger)
        self.lastDeliveredAt = deliveredAt
        self.lastError = nil
        if recordReceipt, let normalizedInstanceID {
            let displayName = filename.flatMap { $0.isEmpty ? nil : $0 } ?? AppStrings.ios_app_onthisphonefilelabel()
            try self.recordRecentReceipt(
                itemID: itemID,
                filename: displayName,
                importID: ShareImportID.validated(serverTimestamp),
                instanceID: normalizedInstanceID,
                deliveredAt: deliveredAt
            )
        }
    }

    /// Persists a 24-hour delivered receipt durably to `recent-receipts.json`, pruning stale entries
    /// (>24h) and capping to 5 newest receipts per journal instance.
    func recordRecentReceipt(
        itemID: String,
        filename: String,
        importID: String?,
        instanceID: String,
        deliveredAt: Date? = nil
    ) throws {
        guard !instanceID.isEmpty else { return }
        try self.ensureRootDirectories()
        let now = self.now()
        let stamp = deliveredAt ?? now
        let epochMs = Int64((stamp.timeIntervalSince1970 * 1000.0).rounded())
        var receipts = self.loadAndPruneRecentReceipts(now: now, persistIfChanged: false)
        receipts.removeAll { $0.id == itemID }
        receipts.append(ImportRecentReceipt(
            id: itemID,
            filename: filename.isEmpty ? AppStrings.ios_app_onthisphonefilelabel() : filename,
            importID: ShareImportID.validated(importID),
            instanceID: instanceID,
            deliveredAtEpochMs: epochMs
        ))
        let pruned = Self.prunedRecentReceipts(receipts, now: now)
        try self.saveRecentReceipts(pruned)
        self.storedRecentReceipts = pruned
    }

    /// Returns up to 5 newest receipts from the last 24 hours for `instanceID`.
    /// Always empty when unpaired, mark-unconfirmed, or paired to a different journal.
    func recentReceipts(
        forInstanceID instanceID: String,
        isPaired: Bool,
        markConfirmed: Bool,
        now: Date? = nil
    ) -> [ImportRecentReceipt] {
        guard isPaired, markConfirmed, !instanceID.isEmpty else { return [] }
        let reference = now ?? self.now()
        let cutoffMs = Self.recentCutoffEpochMs(now: reference)
        return self.storedRecentReceipts
            .filter { $0.instanceID == instanceID && $0.deliveredAtEpochMs >= cutoffMs }
            .sorted(by: Self.recentReceiptSort)
            .prefix(Self.recentReceiptCap)
            .map { $0 }
    }

    func reloadRecentReceiptsFromDisk() {
        self.storedRecentReceipts = self.loadAndPruneRecentReceipts(now: self.now(), persistIfChanged: true)
    }

    nonisolated static func itemIDString(_ itemID: UUID) -> String {
        itemID.uuidString.lowercased()
    }

    static func defaultCacheRootURL(fileManager: FileManager) -> URL {
        do {
            return try AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent("ImportQueue", isDirectory: true)
        } catch {
            preconditionFailure("app group container unavailable: \(error)")
        }
    }
}

extension ShareImportStore {
    struct RawFileInfo {
        let filename: String
        let mimeType: String
    }

    struct FrozenNote {
        let source: String
        let originApp: String?
        let contentType: String
        let filename: String?
        let bytes: Int64
        let basis: String
        let itemTime: String
        let targetJournal: String
        let itemID: String
        var capturedAt: String? = nil
        var importArea: String? = nil
        var importContext: String? = nil
    }

    struct RequestDescriptor: Codable, Equatable, Sendable {
        let source: String
        let filename: String
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case source
            case filename
            case contentType = "content_type"
        }
    }

    struct SaveResult: Codable, Equatable, Sendable {
        let path: String
        let timestamp: String
        let recommendedAction: String
        let source: String?

        enum CodingKeys: String, CodingKey {
            case path
            case timestamp
            case source
            case recommendedAction = "recommended_action"
        }
    }

    nonisolated struct LedgerEntry: Codable, Equatable, Sendable {
        let itemID: String
        let basis: String
        let contentType: String
        let targetJournal: String
        let serverPath: String?
        let serverTimestamp: String?
        let deliveredAt: Date
        let filename: String?
        let originApp: String?
        let itemTime: String?
        let instanceID: String?

        nonisolated init(
            itemID: String,
            basis: String,
            contentType: String,
            targetJournal: String,
            serverPath: String?,
            serverTimestamp: String?,
            deliveredAt: Date,
            filename: String?,
            originApp: String?,
            itemTime: String?,
            instanceID: String? = nil
        ) {
            self.itemID = itemID
            self.basis = basis
            self.contentType = contentType
            self.targetJournal = targetJournal
            self.serverPath = serverPath
            self.serverTimestamp = serverTimestamp
            self.deliveredAt = deliveredAt
            self.filename = filename
            self.originApp = originApp
            self.itemTime = itemTime
            self.instanceID = instanceID
        }

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case basis
            case contentType = "content_type"
            case targetJournal = "target_journal"
            case serverPath = "server_path"
            case serverTimestamp = "server_timestamp"
            case deliveredAt = "delivered_at"
            case filename
            case originApp = "origin_app"
            case itemTime = "item_time"
            case instanceID = "instance_id"
        }
    }
}

extension ShareImportStore {
    enum ItemStatus {
        case staging
        case pending
        case failed
    }

    func ensureRootDirectories() throws {
        try self.fileManager.createDirectory(at: self.stagingDirectoryURL(), withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: self.pendingDirectoryURL(), withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: self.failedDirectoryURL(), withIntermediateDirectories: true)
    }

    func stagingDirectoryURL() -> URL {
        self.cacheRootURL.appendingPathComponent("staging", isDirectory: true)
    }

    func pendingDirectoryURL() -> URL {
        self.cacheRootURL.appendingPathComponent("pending", isDirectory: true)
    }

    func failedDirectoryURL() -> URL {
        self.cacheRootURL.appendingPathComponent("failed", isDirectory: true)
    }

    func ledgerURL() -> URL {
        self.cacheRootURL.appendingPathComponent("ledger.json", isDirectory: false)
    }

    func recentReceiptsURL() -> URL {
        self.cacheRootURL.appendingPathComponent("recent-receipts.json", isDirectory: false)
    }

    func itemDirectoryURL(itemID: String, status: ItemStatus) -> URL {
        switch status {
        case .staging:
            self.stagingItemDirectoryURL(itemID: itemID)
        case .pending:
            self.pendingItemDirectoryURL(itemID: itemID)
        case .failed:
            self.failedItemDirectoryURL(itemID: itemID)
        }
    }

    func stagingItemDirectoryURL(itemID: String) -> URL {
        self.stagingDirectoryURL().appendingPathComponent(itemID, isDirectory: true)
    }

    func pendingItemDirectoryURL(itemID: String) -> URL {
        self.pendingDirectoryURL().appendingPathComponent(itemID, isDirectory: true)
    }

    func failedItemDirectoryURL(itemID: String) -> URL {
        self.failedDirectoryURL().appendingPathComponent(itemID, isDirectory: true)
    }

    func rawURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("raw.bin", isDirectory: false)
    }

    func noteURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("item.json", isDirectory: false)
    }

    func descriptorURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("request.json", isDirectory: false)
    }

    func saveResultURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("save.json", isDirectory: false)
    }

    func failureRecordURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("failure.json", isDirectory: false)
    }

    func requiredFilesExist(itemID: String, status: ItemStatus) -> Bool {
        self.fileManager.fileExists(atPath: self.rawURL(itemID: itemID, status: status).path)
            && self.fileManager.fileExists(atPath: self.noteURL(itemID: itemID, status: status).path)
            && self.fileManager.fileExists(atPath: self.descriptorURL(itemID: itemID, status: status).path)
    }

    func itemDirectories(status: ItemStatus) throws -> [URL] {
        try self.fileManager.contentsOfDirectory(
            at: self.directoryURL(status: status),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter(self.isDirectory)
    }

    func directoryURL(status: ItemStatus) -> URL {
        switch status {
        case .staging:
            self.stagingDirectoryURL()
        case .pending:
            self.pendingDirectoryURL()
        case .failed:
            self.failedDirectoryURL()
        }
    }

    func loadDescriptor(itemID: String, status: ItemStatus) throws -> RequestDescriptor {
        try self.decoder.decode(
            RequestDescriptor.self,
            from: self.payloadIO.readWholeFile(at: self.descriptorURL(itemID: itemID, status: status))
        )
    }

    func loadSaveResultIfPresent(itemID: String, status: ItemStatus) throws -> SaveResult? {
        let url = self.saveResultURL(itemID: itemID, status: status)
        guard self.fileManager.fileExists(atPath: url.path) else { return nil }
        return try self.decoder.decode(SaveResult.self, from: self.payloadIO.readWholeFile(at: url))
    }

    func loadFailureRecordIfPresent(itemID: String, status: ItemStatus) -> ImportFailureRecord? {
        let url = self.failureRecordURL(itemID: itemID, status: status)
        guard self.fileManager.fileExists(atPath: url.path) else { return nil }
        return try? self.decoder.decode(ImportFailureRecord.self, from: self.payloadIO.readWholeFile(at: url))
    }

    func loadLedger() throws -> [String: LedgerEntry] {
        let url = self.ledgerURL()
        guard self.fileManager.fileExists(atPath: url.path) else { return [:] }
        return try self.decoder.decode([String: LedgerEntry].self, from: self.payloadIO.readWholeFile(at: url))
    }

    func saveLedger(_ ledger: [String: LedgerEntry]) throws {
        let data = try self.encoder.encode(ledger)
        try data.write(to: self.ledgerURL(), options: .atomic)
    }

    func loadRecentReceiptsRaw() -> [ImportRecentReceipt] {
        let url = self.recentReceiptsURL()
        guard self.fileManager.fileExists(atPath: url.path),
              let data = try? self.payloadIO.readWholeFile(at: url),
              let decoded = try? self.decoder.decode([ImportRecentReceipt].self, from: data)
        else {
            return []
        }
        return decoded
    }

    func loadAndPruneRecentReceipts(now: Date, persistIfChanged: Bool) -> [ImportRecentReceipt] {
        let raw = self.loadRecentReceiptsRaw()
        let pruned = Self.prunedRecentReceipts(raw, now: now)
        if persistIfChanged && pruned != raw {
            try? self.saveRecentReceipts(pruned)
        }
        return pruned
    }

    func saveRecentReceipts(_ receipts: [ImportRecentReceipt]) throws {
        let data = try self.encoder.encode(receipts)
        try data.write(to: self.recentReceiptsURL(), options: .atomic)
    }

    func removeRecentReceipt(id: String) {
        let now = self.now()
        var receipts = self.loadAndPruneRecentReceipts(now: now, persistIfChanged: false)
        let before = receipts.count
        receipts.removeAll { $0.id == id }
        if receipts.count != before {
            try? self.saveRecentReceipts(receipts)
            self.storedRecentReceipts = receipts
        }
    }

    nonisolated static func recentCutoffEpochMs(now: Date) -> Int64 {
        Int64((now.addingTimeInterval(-Self.recentReceiptTTL).timeIntervalSince1970 * 1000.0).rounded())
    }

    nonisolated static func recentReceiptSort(_ lhs: ImportRecentReceipt, _ rhs: ImportRecentReceipt) -> Bool {
        if lhs.deliveredAtEpochMs == rhs.deliveredAtEpochMs {
            return lhs.id < rhs.id
        }
        return lhs.deliveredAtEpochMs > rhs.deliveredAtEpochMs
    }

    nonisolated static func prunedRecentReceipts(_ receipts: [ImportRecentReceipt], now: Date) -> [ImportRecentReceipt] {
        let cutoffMs = Self.recentCutoffEpochMs(now: now)
        var dedupedByID: [String: ImportRecentReceipt] = [:]
        for receipt in receipts where !receipt.instanceID.isEmpty && receipt.deliveredAtEpochMs >= cutoffMs {
            if let existing = dedupedByID[receipt.id] {
                if receipt.deliveredAtEpochMs > existing.deliveredAtEpochMs {
                    dedupedByID[receipt.id] = receipt
                }
            } else {
                dedupedByID[receipt.id] = receipt
            }
        }
        var byInstance: [String: [ImportRecentReceipt]] = [:]
        for receipt in dedupedByID.values {
            byInstance[receipt.instanceID, default: []].append(receipt)
        }
        var kept: [ImportRecentReceipt] = []
        for instanceReceipts in byInstance.values {
            kept.append(contentsOf: instanceReceipts.sorted(by: Self.recentReceiptSort).prefix(Self.recentReceiptCap))
        }
        return kept.sorted(by: Self.recentReceiptSort)
    }

    func writeData(_ data: Data, to url: URL) throws {
        guard self.fileManager.createFile(atPath: url.path, contents: data) else {
            throw ShareImportStoreError.writeFailed(path: url.path)
        }
    }

    func rotatedLedger(_ ledger: [String: LedgerEntry]) -> [String: LedgerEntry] {
        guard ledger.count > Self.ledgerLimit else { return ledger }
        let kept = ledger.values.sorted {
            if $0.deliveredAt == $1.deliveredAt {
                return $0.itemID < $1.itemID
            }
            return $0.deliveredAt > $1.deliveredAt
        }.prefix(Self.ledgerLimit)
        let droppedCount = ledger.count - kept.count
        if droppedCount > 0 {
            self.ledgerDropSink(droppedCount)
        }
        // OnThisPhoneView renders all delivered share rows uncapped, so rotation truncates visible delivered-share history.
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.itemID, $0) })
    }

    func refreshCounts() {
        self.pendingCount = self.countItemDirectories(at: self.pendingDirectoryURL())
        self.failedCount = self.countItemDirectories(at: self.failedDirectoryURL())
    }

    func countItemDirectories(at url: URL) -> Int {
        ((try? self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter(self.isDirectory).count
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

extension ShareImportStore {
    func localOnThisPhoneItem(
        itemID: String,
        status: ItemStatus,
        location: OnThisPhoneLocation
    ) -> OnThisPhoneItem {
        let object = self.readNoteObject(itemID: itemID, status: status)
        let rawURL = self.rawURL(itemID: itemID, status: status)
        let rawFileURL = self.fileManager.fileExists(atPath: rawURL.path) ? rawURL : nil
        let failureRecord = location == .failed ? self.loadFailureRecordIfPresent(itemID: itemID, status: status) : nil
        let canRetry = location == .failed && failureRecord?.classification != .terminal
        return OnThisPhoneItem(
            id: itemID,
            sourceKind: .share,
            sendState: onThisPhoneSendState(location: location, canRetry: canRetry, isActivelyUploading: false),
            contentType: object?["content_type"] as? String,
            filename: object?["filename"] as? String,
            bytes: (object?["bytes"] as? NSNumber)?.int64Value,
            originApp: object?["origin_app"] as? String,
            basis: object?["basis"] as? String,
            itemTime: Self.parseItemTime(object?["item_time"] as? String),
            targetJournal: object?["target_journal"] as? String,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: rawFileURL,
            failureReason: failureRecord?.reason,
            retryAvailable: canRetry,
            lastAttemptAt: failureRecord?.failedAt
        )
    }

    func deliveredOnThisPhoneItem(itemID: String, entry: LedgerEntry) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: itemID,
            sourceKind: .share,
            sendState: .inYourJournal,
            contentType: entry.contentType,
            filename: entry.filename,
            bytes: nil,
            originApp: entry.originApp,
            basis: entry.basis,
            itemTime: Self.parseItemTime(entry.itemTime),
            targetJournal: entry.targetJournal,
            stream: nil,
            day: Self.dayString(fromServerTimestamp: entry.serverTimestamp),
            segment: nil,
            deliveredAt: entry.deliveredAt,
            rawFileURL: nil,
            importID: ShareImportID.validated(entry.serverTimestamp)
        )
    }

    func readNoteObject(itemID: String, status: ItemStatus) -> [String: Any]? {
        guard let data = try? self.payloadIO.readWholeFile(at: self.noteURL(itemID: itemID, status: status)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func rawFileInfo(for contentType: String) -> RawFileInfo {
        switch contentType {
        case "public.mpeg-4-audio", "com.apple.m4a-audio", "public.m4a-audio", "audio/m4a", "audio/mp4":
            return RawFileInfo(filename: "audio.m4a", mimeType: "audio/mp4")
        case "com.adobe.pdf", "application/pdf":
            return RawFileInfo(filename: "document.pdf", mimeType: "application/pdf")
        case "public.jpeg", "public.jpg", "image/jpeg":
            return RawFileInfo(filename: "image.jpg", mimeType: "image/jpeg")
        case "public.png", "image/png":
            return RawFileInfo(filename: "image.png", mimeType: "image/png")
        case "public.heic", "public.heif", "image/heic", "image/heif":
            return RawFileInfo(filename: "image.heic", mimeType: "image/heic")
        case "com.compuserve.gif", "image/gif":
            return RawFileInfo(filename: "image.gif", mimeType: "image/gif")
        case "org.webmproject.webp", "public.webp", "image/webp":
            return RawFileInfo(filename: "image.webp", mimeType: "image/webp")
        case "public.tiff", "image/tiff":
            return RawFileInfo(filename: "image.tiff", mimeType: "image/tiff")
        case "public.plain-text", "public.utf8-plain-text", "text/plain":
            return RawFileInfo(filename: "text.txt", mimeType: "text/plain")
        default:
            if let type = UTType(contentType) ?? UTType(mimeType: contentType),
               type.conforms(to: .audio) {
                let ext = type.preferredFilenameExtension ?? "audio"
                let mime = type.preferredMIMEType ?? "audio/\(ext)"
                return RawFileInfo(filename: "audio.\(ext)", mimeType: mime)
            }
            if let type = UTType(contentType) ?? UTType(mimeType: contentType),
               let ext = type.preferredFilenameExtension {
                return RawFileInfo(filename: "item.\(ext)", mimeType: type.preferredMIMEType ?? "application/octet-stream")
            }
            return RawFileInfo(filename: "item.bin", mimeType: "application/octet-stream")
        }
    }

    nonisolated static func orderedNoteData(_ note: FrozenNote) throws -> Data {
        var json = "{"
            + "\"schema\":\"solstone.source.item/1\","
            + "\"source\":\(try Self.jsonString(note.source)),"
            + "\"origin_app\":\(try Self.optionalJSONString(note.originApp)),"
            + "\"content_type\":\(try Self.jsonString(note.contentType)),"
            + "\"filename\":\(try Self.optionalJSONString(note.filename)),"
            + "\"bytes\":\(note.bytes),"
            + "\"basis\":\(try Self.jsonString(note.basis)),"
            + "\"item_time\":\(try Self.jsonString(note.itemTime)),"
            + "\"target_journal\":\(try Self.jsonString(note.targetJournal)),"
            + "\"kind\":\"raw\","
            + "\"item_id\":\(try Self.jsonString(note.itemID))"
        if let capturedAt = note.capturedAt, !capturedAt.isEmpty {
            json += ",\"captured_at\":\(try Self.jsonString(capturedAt))"
        }
        if let area = note.importArea {
            json += ",\"import_area\":\(try Self.jsonString(area))"
        }
        if let context = note.importContext {
            json += ",\"import_context\":\(try Self.jsonString(context))"
        }
        json += "}"
        return Data(json.utf8)
    }

    nonisolated static func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ShareImportStoreError.writeFailed(path: "json-string")
        }
        return string
    }

    nonisolated static func optionalJSONString(_ value: String?) throws -> String {
        guard let value else { return "null" }
        return try Self.jsonString(value)
    }

    nonisolated static func iso8601String(for date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated static func parseItemTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        let defaultFormatter = ISO8601DateFormatter()
        if let date = defaultFormatter.date(from: value) {
            return date
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value)
    }

    nonisolated static func dayString(fromServerTimestamp timestamp: String?) -> String? {
        guard let date = Self.parseItemTime(timestamp) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

enum ShareImportStoreError: Error, Equatable, Sendable {
    case writeFailed(path: String)
    case missingRequiredArtifact(itemID: String)
    case noteDecodeFailed(itemID: String)
    case textDecodeFailed(itemID: String)
    case noRoom
    case tooLarge
    case protected
    case undecodable
    case unreadable
}
