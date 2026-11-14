// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os

nonisolated private let obsidianStoreLog = Logger(subsystem: "app.solstone.swift", category: "obsidian")

nonisolated struct ObsidianNoteRecord: Codable, Equatable, Sendable {
    var path: String
    var documentIdentifier: Int?
    var mtimeMs: Int64
    var sizeBytes: Int64
    var contentHash: String
    var text: String
    var lastReportedTime: Int64?
    var lastReportedWindowKey: String?
    var firstObservedMissingAt: Int64?
    var logicalID: String = UUID().uuidString
    var representedPath: String? = nil
    var intakeKept: Bool = false
    var contentIsCurrent: Bool = true
    var firstMissingStamp: ObsidianStamp? = nil
    var lastImmutableWindowStart: Int64? = nil
}

nonisolated struct ObsidianPendingChange: Codable, Equatable, Sendable {
    var change: ObsidianChange
    var vault: String
    var path: String
    var previousPath: String?
    var changedAt: ObsidianStamp
    var observedAt: ObsidianStamp
    var text: String?
    var contentHash: String?
    var logicalKey: String
    var windowKey: String
    var documentIdentifier: Int?
    var firstSight: Bool = false
}

nonisolated struct ObsidianOutboxItem: Codable, Equatable, Sendable {
    var itemID: UUID
    var filename: String
    var window: ObsidianWindow
    var createdAt: Date
    var lineCount: Int
    var byteCount: Int
    var sha256Hex: String
    var timeZoneIdentifier: String
    var offsetSeconds: Int32
    var vaultID: String
    var folderName: String
    var noteIdentityHashes: [String] = []
}

nonisolated struct ObsidianVaultState: Codable, Equatable, Sendable {
    var id: String
    var folderName: String
    var bookmarkData: Data?
    var rootDocumentIdentifier: Int?
    var table: [String: ObsidianNoteRecord] = [:]
    var pendingChanges: [ObsidianPendingChange] = []
    var outboxItems: [ObsidianOutboxItem] = []
    var frozenBaselineHashes: [String] = []
    var unappliedIntakeOps: [ObsidianUnappliedIntakeOp] = []
    /// The same-name vault check passed for the journal paired now. A new pairing clears it.
    var sameNameChecked: Bool = false
    var lastChecked: Date?
    var unavailableCount: Int = 0
    var tooLargeCount: Int = 0
    var foundNotesCount: Int = 0
    var foundNoteIdentities: Set<String> = []
    var baselineCompleted: Bool = false
    var intakeSequence: UInt64 = 0

    /// A new journal gets the vault's first setup again: every note is sent once more, after
    /// the same-name check, while held windows and the outbox stay as they are.
    mutating func restartFirstSetup() {
        for path in self.table.keys {
            self.table[path]?.representedPath = nil
            self.table[path]?.lastReportedTime = nil
            self.table[path]?.lastReportedWindowKey = nil
            self.table[path]?.lastImmutableWindowStart = nil
        }
        self.sameNameChecked = false
    }
}

nonisolated extension ObsidianVaultState {
    /// Fields absent from an older store decode to their defaults. A store written before the
    /// same-name flag carries it under an earlier key, read once here.
    private enum EarlierKeys: String, CodingKey {
        case acceptedSameNameEndpoints
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let earlier = try decoder.container(keyedBy: EarlierKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.folderName = try container.decode(String.self, forKey: .folderName)
        self.bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        self.rootDocumentIdentifier = try container.decodeIfPresent(Int.self, forKey: .rootDocumentIdentifier)
        self.table = try container.decodeIfPresent([String: ObsidianNoteRecord].self, forKey: .table) ?? [:]
        self.pendingChanges = try container.decodeIfPresent([ObsidianPendingChange].self, forKey: .pendingChanges) ?? []
        self.outboxItems = try container.decodeIfPresent([ObsidianOutboxItem].self, forKey: .outboxItems) ?? []
        self.frozenBaselineHashes = try container.decodeIfPresent([String].self, forKey: .frozenBaselineHashes) ?? []
        self.unappliedIntakeOps = try container.decodeIfPresent([ObsidianUnappliedIntakeOp].self, forKey: .unappliedIntakeOps) ?? []
        self.sameNameChecked = try container.decodeIfPresent(Bool.self, forKey: .sameNameChecked)
            ?? !((try earlier.decodeIfPresent([String].self, forKey: .acceptedSameNameEndpoints)) ?? []).isEmpty
        self.lastChecked = try container.decodeIfPresent(Date.self, forKey: .lastChecked)
        self.unavailableCount = try container.decodeIfPresent(Int.self, forKey: .unavailableCount) ?? 0
        self.tooLargeCount = try container.decodeIfPresent(Int.self, forKey: .tooLargeCount) ?? 0
        self.foundNotesCount = try container.decodeIfPresent(Int.self, forKey: .foundNotesCount) ?? 0
        self.foundNoteIdentities = try container.decodeIfPresent(Set<String>.self, forKey: .foundNoteIdentities) ?? []
        self.baselineCompleted = try container.decodeIfPresent(Bool.self, forKey: .baselineCompleted) ?? false
        self.intakeSequence = try container.decodeIfPresent(UInt64.self, forKey: .intakeSequence) ?? 0
    }
}

nonisolated struct ObsidianStoreDocument: Codable, Equatable, Sendable {
    var version: Int = 1
    var selectedVaultID: String?
    var enabled: Bool = false
    var paused: Bool = false
    var generation: UInt64 = 0
    var vaults: [String: ObsidianVaultState] = [:]
}

/// Notes the journal paired now acknowledged, by vault, in a small file beside store.json, so an
/// acknowledgement does not rewrite every note's text.
nonisolated struct ObsidianDeliveredDocument: Codable, Equatable, Sendable {
    var version: Int = 1
    var vaults: [String: Set<String>] = [:]
}

/// Where a store written before the delivered file kept that progress: inside each vault, or
/// earlier still, one set per journal.
nonisolated private struct ObsidianStoreDeliveredLegacy: Decodable {
    struct Vault: Decodable {
        var deliveredNotes: Set<String>?
        var acknowledgedNotesByJournal: [String: Set<String>]?

        var delivered: Set<String>? {
            if let deliveredNotes { return deliveredNotes }
            // Which earlier journal is paired now is not known here, so a note counts only if
            // every one of them acknowledged it.
            return self.acknowledgedNotesByJournal.map { sets in
                sets.values.dropFirst().reduce(sets.values.first ?? []) { $0.intersection($1) }
            }
        }
    }
    var vaults: [String: Vault]?
}

nonisolated struct ObsidianPreparedCheckpoint: Sendable {
    let document: ObsidianStoreDocument
    let temporaryURL: URL
}

@MainActor
final class ObsidianStore {
    let rootURL: URL
    let fileManager: FileManager

    var document: ObsidianStoreDocument = ObsidianStoreDocument() {
        didSet { self.revision &+= 1 }
    }
    private(set) var isLoaded: Bool = false
    private(set) var hasFault: Bool = false
    private(set) var revision: UInt64 = 0
    /// Notes the journal paired now acknowledged, by vault. A new pairing clears it.
    private(set) var deliveredNotes: [String: Set<String>] = [:]
    /// The delivered file is behind `deliveredNotes`. It is written before store.json is, so
    /// after a crash between the two, progress can read low (a resend, which the journal
    /// answers as already held) but never high.
    private var deliveredUnsaved = false
    /// store.json still holds progress from before the delivered file.
    private var legacyProgressInStore = false

    /// Test hook to simulate private write failures.
    var testFailNextSave: Bool = false
    var testFailNextDeliveredSave: Bool = false

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootURL = base.appendingPathComponent("Obsidian", isDirectory: true)
        }
        self.load()
    }

    var storeFileURL: URL {
        self.rootURL.appendingPathComponent("store.json")
    }

    var outboxDirectoryURL: URL {
        self.rootURL.appendingPathComponent("outbox", isDirectory: true)
    }

    var deliveredFileURL: URL {
        self.rootURL.appendingPathComponent("delivered.json")
    }

    func load() {
        guard !self.isLoaded else { return }
        let url = self.storeFileURL
        guard self.fileManager.fileExists(atPath: url.path) else {
            self.document = ObsidianStoreDocument()
            self.isLoaded = true
            self.hasFault = false
            return
        }

        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                self.isLoaded = false
                self.hasFault = true
                obsidianStoreLog.error("store.json is empty")
                return
            }
            let doc = try JSONDecoder().decode(ObsidianStoreDocument.self, from: data)
            guard doc.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            self.document = doc
            self.loadDelivered(storeData: data)
            self.isLoaded = true
            self.hasFault = false
            if self.legacyProgressInStore { self.finishLegacyProgressMove() }
        } catch {
            // A present file that does not decode is a fault: isLoaded stays false, bytes stay, private-store sentence.
            self.isLoaded = false
            self.hasFault = true
            obsidianStoreLog.error("store.json decode failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A store from before the delivered file carries the progress in store.json. Where both
    /// hold a vault's progress (an earlier build wrote store.json since), a note counts only if
    /// both say so: progress never reads higher than the truth.
    private func loadDelivered(storeData: Data) {
        var legacy: [String: Set<String>] = [:]
        let carriesProgress = ["\"deliveredNotes\":", "\"acknowledgedNotesByJournal\":"].contains {
            storeData.range(of: Data($0.utf8)) != nil
        }
        if carriesProgress, let earlier = try? JSONDecoder().decode(ObsidianStoreDeliveredLegacy.self, from: storeData) {
            for (vaultID, vault) in earlier.vaults ?? [:] {
                if let delivered = vault.delivered { legacy[vaultID] = delivered }
            }
        }
        var delivered = legacy
        if let data = try? Data(contentsOf: self.deliveredFileURL) {
            if let file = try? JSONDecoder().decode(ObsidianDeliveredDocument.self, from: data), file.version == 1 {
                delivered = file.vaults
                for (vaultID, earlier) in legacy {
                    delivered[vaultID] = (delivered[vaultID] ?? []).intersection(earlier)
                }
            } else {
                // Only a count rests on it, and reading none is never higher than the truth.
                obsidianStoreLog.error("delivered.json decode failed")
                delivered = [:]
            }
        }
        self.deliveredNotes = delivered
        // store.json stops carrying the progress at its next save, so the file goes first.
        self.deliveredUnsaved = !legacy.isEmpty
        self.legacyProgressInStore = !legacy.isEmpty
    }

    /// While store.json still carries the old progress, a relaunch counts only what both files
    /// agree on, which would forget an ack recorded since. So the move finishes at once: the
    /// delivered file first, then store.json without the progress. A failure is retried at the
    /// next ack.
    private func finishLegacyProgressMove() {
        do {
            try self.save()
            self.legacyProgressInStore = false
        } catch {
            obsidianStoreLog.error("moving delivered progress out of store.json failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Adds acknowledged notes. Durable before it returns; a failure changes nothing.
    @discardableResult
    func recordDelivered(_ identities: Set<String>, vaultID: String) throws -> Bool {
        guard self.isLoaded, !self.hasFault else { throw CocoaError(.fileWriteUnknown) }
        var next = self.deliveredNotes
        guard !(next[vaultID] ?? []).isSuperset(of: identities) else { return false }
        next[vaultID, default: []].formUnion(identities)
        try self.writeDelivered(next)
        self.deliveredNotes = next
        self.deliveredUnsaved = false
        if self.legacyProgressInStore { self.finishLegacyProgressMove() }
        return true
    }

    /// A new pairing: no note counts as delivered to the journal paired now. Written by the next
    /// save, ahead of store.json.
    func clearDelivered() {
        self.deliveredNotes = [:]
        self.deliveredUnsaved = true
    }

    private func flushDeliveredIfNeeded() throws {
        guard self.deliveredUnsaved else { return }
        try self.writeDelivered(self.deliveredNotes)
        self.deliveredUnsaved = false
    }

    private func writeDelivered(_ vaults: [String: Set<String>]) throws {
        if self.testFailNextDeliveredSave {
            self.testFailNextDeliveredSave = false
            throw CocoaError(.fileWriteUnknown)
        }
        try self.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ObsidianDeliveredDocument(vaults: vaults))
        try data.write(to: self.deliveredFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var fileURL = self.deliveredFileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
    }

    func save() throws {
        guard self.isLoaded, !self.hasFault else {
            throw CocoaError(.fileWriteUnknown)
        }
        try self.flushDeliveredIfNeeded()
        if self.testFailNextSave {
            self.testFailNextSave = false
            throw CocoaError(.fileWriteUnknown)
        }
        try self.ensureDirectories()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self.document)

        let tempURL = self.rootURL.appendingPathComponent(".store-write-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        do {
            if self.fileManager.fileExists(atPath: self.storeFileURL.path) {
                _ = try self.fileManager.replaceItemAt(self.storeFileURL, withItemAt: tempURL)
            } else {
                try self.fileManager.moveItem(at: tempURL, to: self.storeFileURL)
            }
        } catch {
            try? self.fileManager.removeItem(at: tempURL)
            throw error
        }

        try? self.fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: self.storeFileURL.path
        )
        var fileURL = self.storeFileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
        self.revision &+= 1
    }

    nonisolated static func prepare(_ document: ObsidianStoreDocument, rootURL: URL) throws -> ObsidianPreparedCheckpoint {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try Task.checkCancellation()
        let url = rootURL.appendingPathComponent(".store-write-\(UUID().uuidString).tmp")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return ObsidianPreparedCheckpoint(document: document, temporaryURL: url)
    }

    /// The expensive encode/write already happened on a utility task. The
    /// caller checks the source revision immediately before this atomic move.
    func commitPrepared(_ prepared: ObsidianPreparedCheckpoint) throws {
        guard self.isLoaded, !self.hasFault else { throw CocoaError(.fileWriteUnknown) }
        try self.flushDeliveredIfNeeded()
        if self.testFailNextSave {
            self.testFailNextSave = false
            throw CocoaError(.fileWriteUnknown)
        }
        if self.fileManager.fileExists(atPath: self.storeFileURL.path) {
            _ = try self.fileManager.replaceItemAt(self.storeFileURL, withItemAt: prepared.temporaryURL)
        } else {
            try self.fileManager.moveItem(at: prepared.temporaryURL, to: self.storeFileURL)
        }
        self.document = prepared.document
        self.revision &+= 1
    }

    func ensureDirectories() throws {
        try self.fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var root = self.rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)

        try self.fileManager.createDirectory(
            at: self.outboxDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var outbox = self.outboxDirectoryURL
        try outbox.setResourceValues(values)
    }

    func writeOutboxPayload(itemID: UUID, bytes: Data) throws -> URL {
        try self.ensureDirectories()
        let fileURL = self.outboxDirectoryURL.appendingPathComponent("\(itemID.uuidString).jsonl")
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resourceURL = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
        return fileURL
    }

    func removeOutboxPayload(itemID: UUID) {
        let fileURL = self.outboxDirectoryURL.appendingPathComponent("\(itemID.uuidString).jsonl")
        try? self.fileManager.removeItem(at: fileURL)
    }

    var selectedVault: ObsidianVaultState? {
        guard let id = self.document.selectedVaultID else { return nil }
        return self.document.vaults[id]
    }

    func updateSelectedVault(_ mutate: (inout ObsidianVaultState) -> Void) throws {
        guard let id = self.document.selectedVaultID, var vault = self.document.vaults[id] else { return }
        mutate(&vault)
        self.document.vaults[id] = vault
        try self.save()
    }
}
