// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let photosLibraryStoreLog = Logger(subsystem: "app.solstone.swift", category: "photos-library")

/// Persistent local state for the Photos Library source on this device.
/// Holds no photo pixels and no library metadata rows — only the incremental
/// change token, device-local sent counter, and enable/pause flags.
nonisolated struct PhotosLibraryDocument: Codable, Equatable, Sendable {
    var schema: Int = 1
    var everEnabled = false
    var enabled = false
    var paused = false
    var scanComplete = false
    var itemsChecked = 0
    var itemsTotal = 0
    var changeToken: Data?
    var lastScanAt: Date?
    var lastUploadAt: Date?
    var sentCount = 0
    var icloudWaitingCount = 0
}

@MainActor
final class PhotosLibraryStore {
    let fileURL: URL
    private let fileManager: FileManager
    var document = PhotosLibraryDocument()
    private var persisted: PhotosLibraryDocument?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.load()
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("PhotosLibrary", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    func load() {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(PhotosLibraryDocument.self, from: data),
              decoded.schema == 1
        else { return }
        self.document = decoded
        self.persisted = decoded
    }

    func save() {
        if self.persisted == self.document { return }
        do {
            try self.fileManager.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self.document)
            try data.write(to: self.fileURL, options: .atomic)
            self.persisted = self.document
            try? self.fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: self.fileURL.path
            )
            var written = self.fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? written.setResourceValues(values)
        } catch {
            photosLibraryStoreLog.error("photos library state write failed")
        }
    }

    /// Clear per-journal sync progress and change token on re-pairing to a new
    /// journal while preserving OS PhotoKit permission (Privacy Principle 9).
    func resetForNewPairing() {
        self.document = PhotosLibraryDocument()
        self.save()
    }
}
