// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let photoLibraryStoreLog = Logger(subsystem: "app.solstone.swift", category: "photo-library")

/// The on-device record of library imports. Asset identifiers stay in this file and never
/// leave the device; the journal receives only the photos themselves.
@MainActor
final class PhotoLibraryImportStore {
    nonisolated static let schema = "solstone.photos.library/1"
    nonisolated static let batchLimit = 20

    private struct Document: Codable {
        var schema: String
        var batches: [PhotoLibraryBatch]
        /// Every asset brought in from this device, so a later import leaves it out.
        var imported: [String]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var document: Document

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.document = Self.load(fileURL: fileURL, fileManager: fileManager)
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        ShareImportStore.defaultCacheRootURL(fileManager: fileManager)
            .appendingPathComponent("photo-library.json", isDirectory: false)
    }

    /// Newest first.
    var batches: [PhotoLibraryBatch] {
        self.document.batches
    }

    var latest: PhotoLibraryBatch? {
        self.document.batches.first
    }

    var importedAssetIDs: Set<String> {
        Set(self.document.imported)
    }

    func save(_ batch: PhotoLibraryBatch) {
        if let index = self.document.batches.firstIndex(where: { $0.id == batch.id }) {
            self.document.batches[index] = batch
        } else {
            self.document.batches.insert(batch, at: 0)
            if self.document.batches.count > Self.batchLimit {
                self.document.batches.removeLast(self.document.batches.count - Self.batchLimit)
            }
        }
        var imported = Set(self.document.imported)
        for assetID in batch.itemIDs.keys where !imported.contains(assetID) {
            imported.insert(assetID)
            self.document.imported.append(assetID)
        }
        self.write()
    }

    private func write() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self.document)
            try self.fileManager.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: self.fileURL, options: .atomic)
        } catch {
            photoLibraryStoreLog.error("photo library record write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(fileURL: URL, fileManager: FileManager) -> Document {
        let empty = Document(schema: Self.schema, batches: [], imported: [])
        guard fileManager.fileExists(atPath: fileURL.path) else { return empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
            return document.schema == Self.schema ? document : empty
        } catch {
            photoLibraryStoreLog.error("photo library record unreadable: \(String(describing: error), privacy: .public)")
            return empty
        }
    }
}
