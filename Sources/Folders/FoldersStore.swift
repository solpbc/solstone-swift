// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let foldersStoreLog = Logger(subsystem: "app.solstone.swift", category: "folders")

/// Atomic persistence for configured folders and per-file state (`Application Support/Folders/ledger.json`).
/// Stores zero journal identity.
@MainActor
final class FoldersStore {
    let fileURL: URL
    private let fileManager: FileManager
    var ledger = FolderLedger()
    private(set) var isLoaded = true
    private(set) var loadFailed = false

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.load()
    }

    nonisolated static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Folders", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    func load() {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else {
            self.ledger = FolderLedger()
            self.isLoaded = true
            self.loadFailed = false
            return
        }
        do {
            let data = try Data(contentsOf: self.fileURL)
            let decoded = try JSONDecoder().decode(FolderLedger.self, from: data)
            guard decoded.v == FolderLedger.currentVersion else {
                foldersStoreLog.error("unsupported folders ledger version \(decoded.v, privacy: .public)")
                self.isLoaded = false
                self.loadFailed = true
                return
            }
            self.ledger = decoded
            self.isLoaded = true
            self.loadFailed = false
        } catch {
            foldersStoreLog.error("failed to load folders ledger: \(String(describing: type(of: error)), privacy: .public)")
            self.isLoaded = false
            self.loadFailed = true
        }
    }

    @discardableResult
    func save() -> Bool {
        // Fail closed: never overwrite a corrupt existing file.
        guard self.isLoaded, !self.loadFailed else { return false }
        do {
            let dir = self.fileURL.deletingLastPathComponent()
            try self.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            var dirValues = URLResourceValues()
            dirValues.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(dirValues)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self.ledger)
            try data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var mutableFile = self.fileURL
            try? mutableFile.setResourceValues(fileValues)
            return true
        } catch {
            foldersStoreLog.error("failed to save folders ledger: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }
}
