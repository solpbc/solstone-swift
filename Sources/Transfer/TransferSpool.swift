// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated protocol TransferFileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func removeItem(at url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func data(contentsOf url: URL) throws -> Data
}

nonisolated final class FoundationTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(atPath path: String) -> Bool {
        self.fileManager.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    func removeItem(at url: URL) throws {
        try self.fileManager.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        _ = try self.fileManager.replaceItemAt(originalURL, withItemAt: newURL)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }

    func data(contentsOf url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

nonisolated struct TransferSpoolSnapshot: Equatable, Sendable {
    var queued: [TransferStoredItem]
    var attention: [TransferStoredItem]
}

nonisolated struct TransferStoredItem: Equatable, Sendable {
    var manifest: TransferManifest
    var directoryURL: URL
}

nonisolated struct TransferSpool: Sendable {
    static let rootDirectoryName = "Transfers"
    static let stagingDirectoryName = "staging"
    static let queuedDirectoryName = "queued"
    static let attentionDirectoryName = "attention"
    static let deleteSinkDirectoryName = "delete-sink"
    static let manifestFilename = "manifest.json"
    static let bodyUploadFilename = "body.upload"

    let rootURL: URL
    private let fileSystem: any TransferFileSystem

    init(
        rootURL: URL,
        fileSystem: any TransferFileSystem = FoundationTransferFileSystem()
    ) {
        self.rootURL = rootURL
        self.fileSystem = fileSystem
    }

    init(
        fileManager: FileManager = .default,
        fileSystem: (any TransferFileSystem)? = nil
    ) throws {
        let root = try AppGroupContainer.rootURL(fileManager: fileManager)
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        self.init(rootURL: root, fileSystem: fileSystem ?? FoundationTransferFileSystem(fileManager: fileManager))
    }

    var stagingDirectoryURL: URL {
        self.rootURL.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    }

    var queuedDirectoryURL: URL {
        self.rootURL.appendingPathComponent(Self.queuedDirectoryName, isDirectory: true)
    }

    var attentionDirectoryURL: URL {
        self.rootURL.appendingPathComponent(Self.attentionDirectoryName, isDirectory: true)
    }

    var deleteSinkDirectoryURL: URL {
        self.rootURL.appendingPathComponent(Self.deleteSinkDirectoryName, isDirectory: true)
    }

    func initialize(now: Date = Date()) throws -> TransferSpoolSnapshot {
        try self.ensureRootDirectories()
        try? self.fileSystem.removeItem(at: self.deleteSinkDirectoryURL)
        try self.fileSystem.createDirectory(at: self.deleteSinkDirectoryURL, withIntermediateDirectories: true)
        try? self.fileSystem.removeItem(at: self.stagingDirectoryURL)
        try self.fileSystem.createDirectory(at: self.stagingDirectoryURL, withIntermediateDirectories: true)

        var attention = try self.scan(state: .attention)
        var queued: [TransferStoredItem] = []
        for item in try self.scan(state: .queued) {
            if let missing = self.firstMissingRequiredPayload(in: item) {
                let moved = try self.moveQueuedItemToAttention(
                    item,
                    reason: "missing_payload",
                    detail: missing,
                    now: now
                )
                attention.append(moved)
            } else {
                queued.append(item)
            }
        }
        return TransferSpoolSnapshot(queued: queued, attention: attention)
    }

    func stage(manifest: TransferManifest, payloads: [String: Data]) throws -> TransferStoredItem {
        try self.ensureRootDirectories()
        let itemDirectory = self.stagingDirectoryURL.appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
        if self.fileSystem.fileExists(atPath: itemDirectory.path) {
            try self.fileSystem.removeItem(at: itemDirectory)
        }
        try self.fileSystem.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        for part in manifest.payloadParts {
            guard let data = payloads[part.partID] else { continue }
            let url = try self.payloadURL(for: part, in: itemDirectory)
            try self.fileSystem.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try self.fileSystem.write(data, to: url, options: .atomic)
        }
        try self.writeManifestAtomically(manifest.replacingDiskState(.queued), in: itemDirectory)
        return TransferStoredItem(manifest: manifest.replacingDiskState(.queued), directoryURL: itemDirectory)
    }

    func commitStagedItem(itemID: UUID) throws -> TransferStoredItem {
        try self.ensureRootDirectories()
        let sourceURL = self.stagingDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        let destinationURL = self.queuedDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        if self.fileSystem.fileExists(atPath: destinationURL.path) {
            try self.fileSystem.removeItem(at: destinationURL)
        }
        try self.fileSystem.moveItem(at: sourceURL, to: destinationURL)
        var manifest = try self.readManifest(in: destinationURL).replacingDiskState(.queued)
        manifest.attention = nil
        try self.writeManifestAtomically(manifest, in: destinationURL)
        return TransferStoredItem(manifest: manifest, directoryURL: destinationURL)
    }

    func writeManifestAtomically(_ manifest: TransferManifest, in directoryURL: URL) throws {
        try self.fileSystem.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(manifest)
        let manifestURL = self.manifestURL(in: directoryURL)
        let tempURL = directoryURL.appendingPathComponent(".manifest-\(UUID().uuidString).tmp", isDirectory: false)
        try self.fileSystem.write(data, to: tempURL, options: .atomic)
        if self.fileSystem.fileExists(atPath: manifestURL.path) {
            try self.fileSystem.replaceItem(at: manifestURL, withItemAt: tempURL)
        } else {
            try self.fileSystem.moveItem(at: tempURL, to: manifestURL)
        }
    }

    func moveQueuedItemToAttention(
        _ item: TransferStoredItem,
        reason: String,
        detail: String,
        now: Date
    ) throws -> TransferStoredItem {
        try self.ensureRootDirectories()
        var manifest = item.manifest.replacingDiskState(.attention)
        manifest.nextAttemptAt = nil
        manifest.attention = TransferAttentionInfo(reason: reason, shortDetail: detail, movedAt: now)
        try self.writeManifestAtomically(manifest, in: item.directoryURL)
        let destinationURL = self.attentionDirectoryURL.appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
        if self.fileSystem.fileExists(atPath: destinationURL.path) {
            try self.fileSystem.removeItem(at: destinationURL)
        }
        try self.fileSystem.moveItem(at: item.directoryURL, to: destinationURL)
        return TransferStoredItem(manifest: manifest, directoryURL: destinationURL)
    }

    func moveAttentionItemToQueued(_ item: TransferStoredItem) throws -> TransferStoredItem {
        try self.ensureRootDirectories()
        var manifest = item.manifest.replacingDiskState(.queued)
        manifest.attention = nil
        manifest.nextAttemptAt = nil
        try self.writeManifestAtomically(manifest, in: item.directoryURL)
        let destinationURL = self.queuedDirectoryURL.appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
        if self.fileSystem.fileExists(atPath: destinationURL.path) {
            try self.fileSystem.removeItem(at: destinationURL)
        }
        try self.fileSystem.moveItem(at: item.directoryURL, to: destinationURL)
        return TransferStoredItem(manifest: manifest, directoryURL: destinationURL)
    }

    func updateQueuedManifest(_ manifest: TransferManifest, directoryURL: URL) throws -> TransferStoredItem {
        let updated = manifest.replacingDiskState(.queued)
        try self.writeManifestAtomically(updated, in: directoryURL)
        return TransferStoredItem(manifest: updated, directoryURL: directoryURL)
    }

    func bodyCacheURL(for item: TransferStoredItem) -> URL {
        item.directoryURL.appendingPathComponent(Self.bodyUploadFilename, isDirectory: false)
    }

    func bodyCacheExists(for item: TransferStoredItem) -> Bool {
        self.fileSystem.fileExists(atPath: self.bodyCacheURL(for: item).path)
    }

    func writeBodyCache(_ data: Data, for item: TransferStoredItem) throws -> URL {
        let url = self.bodyCacheURL(for: item)
        try self.fileSystem.write(data, to: url, options: .atomic)
        return url
    }

    func removeBodyCache(for item: TransferStoredItem) {
        try? self.fileSystem.removeItem(at: self.bodyCacheURL(for: item))
    }

    func removeCommittedItem(_ item: TransferStoredItem) throws {
        let sink = self.deleteSinkDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.manifest.itemID.uuidString, isDirectory: true)
        try self.fileSystem.createDirectory(at: sink.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileSystem.fileExists(atPath: sink.path) {
            try self.fileSystem.removeItem(at: sink)
        }
        if self.fileSystem.fileExists(atPath: item.directoryURL.path) {
            try self.fileSystem.moveItem(at: item.directoryURL, to: sink)
            try? self.fileSystem.removeItem(at: sink)
        }
    }

    func validatePayloads(for item: TransferStoredItem) -> String? {
        self.firstMissingRequiredPayload(in: item)
    }

    func payloadURL(for part: TransferPayloadPartDescriptor, in directoryURL: URL) throws -> URL {
        try self.validateRelativePath(part.relativePath)
        return directoryURL.appendingPathComponent(part.relativePath, isDirectory: false)
    }

    func payloadData(for part: TransferPayloadPartDescriptor, in item: TransferStoredItem) throws -> Data {
        try self.fileSystem.data(contentsOf: self.payloadURL(for: part, in: item.directoryURL))
    }

    private func ensureRootDirectories() throws {
        for url in [
            self.rootURL,
            self.stagingDirectoryURL,
            self.queuedDirectoryURL,
            self.attentionDirectoryURL,
            self.deleteSinkDirectoryURL,
        ] {
            try self.fileSystem.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func scan(state: TransferDiskState) throws -> [TransferStoredItem] {
        let directory = state == .queued ? self.queuedDirectoryURL : self.attentionDirectoryURL
        guard self.fileSystem.fileExists(atPath: directory.path) else { return [] }
        var items: [TransferStoredItem] = []
        for url in try self.fileSystem.contentsOfDirectory(at: directory) {
            guard let manifest = try? self.readManifest(in: url).validated(for: state) else { continue }
            items.append(TransferStoredItem(manifest: manifest, directoryURL: url))
        }
        return items.sorted {
            if $0.manifest.createdAt == $1.manifest.createdAt {
                return $0.manifest.itemID.uuidString < $1.manifest.itemID.uuidString
            }
            return $0.manifest.createdAt < $1.manifest.createdAt
        }
    }

    private func firstMissingRequiredPayload(in item: TransferStoredItem) -> String? {
        for part in item.manifest.payloadParts where part.requiredForDispatch {
            guard let url = try? self.payloadURL(for: part, in: item.directoryURL),
                  self.fileSystem.fileExists(atPath: url.path)
            else {
                return part.filename
            }
        }
        return nil
    }

    private func readManifest(in directoryURL: URL) throws -> TransferManifest {
        try Self.decoder().decode(TransferManifest.self, from: self.fileSystem.data(contentsOf: self.manifestURL(in: directoryURL)))
    }

    private func manifestURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(Self.manifestFilename, isDirectory: false)
    }

    private func validateRelativePath(_ relativePath: String) throws {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw TransferManifestError.invalidRelativePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TransferManifestError.invalidRelativePath(relativePath)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
