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
    var acceptedSameNameEndpoints: [String] = []
    var lastChecked: Date?
    var unavailableCount: Int = 0
    var tooLargeCount: Int = 0
    var acknowledgedNotesByJournal: [String: Set<String>] = [:]
    var foundNotesCount: Int = 0
    var foundNoteIdentities: Set<String> = []
    var baselineCompleted: Bool = false
    var intakeSequence: UInt64 = 0
}

nonisolated struct ObsidianStoreDocument: Codable, Equatable, Sendable {
    var version: Int = 1
    var selectedVaultID: String?
    var enabled: Bool = false
    var paused: Bool = false
    var generation: UInt64 = 0
    var vaults: [String: ObsidianVaultState] = [:]
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

    /// Test hook to simulate private write failures.
    var testFailNextSave: Bool = false

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
            self.isLoaded = true
            self.hasFault = false
        } catch {
            // A present file that does not decode is a fault: isLoaded stays false, bytes stay, private-store sentence.
            self.isLoaded = false
            self.hasFault = true
            obsidianStoreLog.error("store.json decode failed: \(String(describing: error), privacy: .public)")
        }
    }

    func save() throws {
        guard self.isLoaded, !self.hasFault else {
            throw CocoaError(.fileWriteUnknown)
        }
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
