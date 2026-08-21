// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import os

nonisolated private let transferSpoolLog = Logger(subsystem: "app.solstone.swift", category: "transfer-spool")

nonisolated protocol TransferByteSink {
    func append(_ data: Data) throws
    func append(contentsOf url: URL) throws
}

nonisolated protocol TransferFileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func removeItem(at url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func data(contentsOf url: URL) throws -> Data
    func byteCount(at url: URL) throws -> Int
    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws
    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int
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

    func byteCount(at url: URL) throws -> Int {
        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.intValue
    }

    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return }
            try consume(data)
        }
    }

    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try self.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileExists(atPath: url.path) {
            try self.removeItem(at: url)
        }
        guard self.fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let sink = FileHandleTransferByteSink(handle: handle, fileSystem: self)
        try body(sink)
        try handle.synchronize()
        return sink.byteCount
    }
}

nonisolated private final class FileHandleTransferByteSink: TransferByteSink, @unchecked Sendable {
    private let handle: FileHandle
    private let fileSystem: FoundationTransferFileSystem
    private(set) var byteCount = 0

    init(handle: FileHandle, fileSystem: FoundationTransferFileSystem) {
        self.handle = handle
        self.fileSystem = fileSystem
    }

    func append(_ data: Data) throws {
        try self.handle.write(contentsOf: data)
        self.byteCount += data.count
    }

    func append(contentsOf url: URL) throws {
        try self.fileSystem.readChunks(at: url, chunkSize: 64 * 1024) { chunk in
            try self.handle.write(contentsOf: chunk)
            self.byteCount += chunk.count
        }
    }
}

nonisolated struct TransferSpoolSnapshot: Equatable, Sendable {
    var queued: [TransferStoredItem]
    var attention: [TransferStoredItem]
    var recoveryMoves: [TransferRecoveryMove]
    var recoveryDiagnostics: [TransferRecoveryDiagnostic]
    var conflictedItemIDs: Set<UUID>
}

nonisolated struct TransferRecoveryMove: Equatable, Sendable {
    var item: TransferStoredItem
    var previousState: TransferDiskState
    var reason: String
    var detail: String
}

nonisolated enum TransferSpoolError: Error, Equatable, Sendable {
    case destinationAlreadyExists(String)
    case partialFileMove(itemID: UUID, consumedPartIDs: [String], failedPartID: String, detail: String)
}

nonisolated struct TransferStoredItem: Equatable, Sendable {
    var manifest: TransferManifest
    var directoryURL: URL
}

nonisolated struct TransferSpoolStageResult: Equatable, Sendable {
    var item: TransferStoredItem
    var recoveryDiagnostics: [TransferRecoveryDiagnostic]
}

nonisolated struct TransferRecoveryDiagnostic: Equatable, Sendable {
    var source: String
    var itemID: UUID
    var previousState: TransferRuntimeState
    var nextState: TransferRuntimeState
    var outcome: TransferDiagnosticOutcomeSummary
    var detail: String
}

nonisolated enum TransferOwnershipConflictReason: Equatable, Sendable {
    case ownerConflict
    case manifestMismatch
    case manifestUndecodable
    case payloadMismatch
    case payloadUnreadable
}

nonisolated enum TransferOwnershipVerdict: Equatable, Sendable {
    case ownedInQueued
    case ownedInAttention
    case conflict(TransferOwnershipConflictReason)
    case stagingOnly
    case salvageOnly
    case notFound
}

nonisolated struct TransferSpool: Sendable {
    static let rootDirectoryName = "Transfers"
    static let stagingDirectoryName = "staging"
    static let queuedDirectoryName = "queued"
    static let attentionDirectoryName = "attention"
    static let deleteSinkDirectoryName = "delete-sink"
    static let salvageDirectoryName = "salvage"
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

    var salvageDirectoryURL: URL {
        self.rootURL.appendingPathComponent(Self.salvageDirectoryName, isDirectory: true)
    }

    func initialize(now: Date = Date()) throws -> TransferSpoolSnapshot {
        let conflictedItemIDs = self.conflictedItemIDs()
        try self.ensureRootDirectories()
        try? self.fileSystem.removeItem(at: self.deleteSinkDirectoryURL)
        try self.fileSystem.createDirectory(at: self.deleteSinkDirectoryURL, withIntermediateDirectories: true)

        var recoveryDiagnostics = try self.normalizePersistedObserverIngestItems(
            state: .attention,
            excluding: conflictedItemIDs,
            now: now
        )
        recoveryDiagnostics.append(contentsOf: try self.normalizePersistedObserverIngestItems(
            state: .queued,
            excluding: conflictedItemIDs,
            now: now
        ))

        var attention = try self.scan(state: .attention, excluding: conflictedItemIDs)
        var queued: [TransferStoredItem] = []
        var recoveryMoves: [TransferRecoveryMove] = []
        for item in try self.scan(state: .queued, excluding: conflictedItemIDs) {
            if let missing = self.firstMissingRequiredPayload(in: item) {
                let moved = try self.moveQueuedItemToAttention(
                    item,
                    reason: "missing_payload",
                    detail: missing,
                    now: now
                )
                attention.append(moved)
                recoveryMoves.append(TransferRecoveryMove(
                    item: moved,
                    previousState: .queued,
                    reason: "missing_payload",
                    detail: missing
                ))
            } else {
                queued.append(item)
            }
        }
        let committedItemIDs = Set((queued + attention).map(\.manifest.itemID))
        let stagedRecovery = try self.recoverStagedItems(
            knownCommittedItemIDs: committedItemIDs,
            excluding: conflictedItemIDs,
            now: now
        )
        queued.append(contentsOf: stagedRecovery.promoted)
        attention.append(contentsOf: stagedRecovery.attention)
        recoveryDiagnostics.append(contentsOf: conflictedItemIDs.sorted { $0.uuidString < $1.uuidString }.map {
            TransferRecoveryDiagnostic(
                source: self.rootURL.path,
                itemID: $0,
                previousState: .held,
                nextState: .held,
                outcome: .needsAttention,
                detail: "reason=owner conflict"
            )
        })
        recoveryDiagnostics.append(contentsOf: stagedRecovery.diagnostics)
        queued.sort(by: self.itemSort)
        attention.sort(by: self.itemSort)
        return TransferSpoolSnapshot(
            queued: queued,
            attention: attention,
            recoveryMoves: recoveryMoves,
            recoveryDiagnostics: recoveryDiagnostics,
            conflictedItemIDs: conflictedItemIDs
        )
    }

    /// Writes in-memory payload data before its manifest. Unlike file-URL
    /// staging, these bytes have no producer-owned durable source after a crash,
    /// so this deliberate asymmetry retains them in salvage for inspection.
    ///
    /// Declare only parts that physically exist at enqueue time. A part that is
    /// optional by nature, such as a location file that may not exist for a
    /// given segment, is omitted from `payloadParts` for that item; it is never
    /// declared-and-missing. `requiredForDispatch` governs only what happens if
    /// a declared part's file disappears after commit: `true` blocks dispatch
    /// and moves the item to attention, `false` lets delivery proceed with that
    /// part omitted.
    func stage(manifest: TransferManifest, payloads: [String: Data]) throws -> TransferSpoolStageResult {
        try self.ensureRootDirectories()
        var resolvedPayloads: [(part: TransferPayloadPartDescriptor, data: Data)] = []
        for part in manifest.payloadParts {
            guard let data = payloads[part.partID] else {
                throw TransferManifestError.missingPayload(part.partID)
            }
            try self.validateRelativePath(part.relativePath)
            resolvedPayloads.append((part: part, data: data))
        }
        let prepared = try self.prepareStagingDirectory(for: manifest)
        let itemDirectory = prepared.directoryURL
        try self.fileSystem.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        var byteCounts: [String: Int] = [:]
        for (part, data) in resolvedPayloads {
            let url = try self.payloadURL(for: part, in: itemDirectory)
            try self.fileSystem.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try self.fileSystem.write(data, to: url, options: .atomic)
            byteCounts[part.partID] = data.count
        }
        let stagedManifest = self.manifestByApplyingByteCounts(manifest, byteCountsByPartID: byteCounts)
            .replacingDiskState(.queued)
        try self.writeManifestAtomically(stagedManifest, in: itemDirectory)
        return TransferSpoolStageResult(
            item: TransferStoredItem(manifest: stagedManifest, directoryURL: itemDirectory),
            recoveryDiagnostics: prepared.diagnostics
        )
    }

    /// Moves producer-owned payload files into staging without a full-file
    /// `Data` read. It writes a complete manifest before moving any payload, so
    /// staging never contains payload bytes without their manifest. On success
    /// the producer's files are gone from their original URLs. On partial
    /// failure, `TransferSpoolError.partialFileMove` names the parts already
    /// consumed; those producer files are gone, remaining producer files are
    /// untouched, and the partial staging directory is salvaged on the next
    /// `initialize()`.
    ///
    /// Declare only parts that physically exist at enqueue time. A part that is
    /// optional by nature, such as a location file that may not exist for a
    /// given segment, is omitted from `payloadParts` for that item; it is never
    /// declared-and-missing. `requiredForDispatch` governs only what happens if
    /// a declared part's file disappears after commit: `true` blocks dispatch
    /// and moves the item to attention, `false` lets delivery proceed with that
    /// part omitted.
    func stage(manifest: TransferManifest, payloadFileURLs: [String: URL]) throws -> TransferSpoolStageResult {
        try self.ensureRootDirectories()
        var resolvedPayloads: [(part: TransferPayloadPartDescriptor, sourceURL: URL)] = []
        for part in manifest.payloadParts {
            guard let sourceURL = payloadFileURLs[part.partID] else {
                throw TransferManifestError.missingPayload(part.partID)
            }
            try self.validateRelativePath(part.relativePath)
            resolvedPayloads.append((part: part, sourceURL: sourceURL))
        }
        let prepared = try self.prepareStagingDirectory(for: manifest)
        let itemDirectory = prepared.directoryURL
        try self.fileSystem.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        var byteCounts: [String: Int] = [:]
        for (part, sourceURL) in resolvedPayloads {
            byteCounts[part.partID] = try self.fileSystem.byteCount(at: sourceURL)
        }
        let stagedManifest = self.manifestByApplyingByteCounts(manifest, byteCountsByPartID: byteCounts)
            .replacingDiskState(.queued)
        try self.writeManifestAtomically(stagedManifest, in: itemDirectory)
        var consumedPartIDs: [String] = []
        for (part, sourceURL) in resolvedPayloads {
            let destinationURL = try self.payloadURL(for: part, in: itemDirectory)
            do {
                try self.fileSystem.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try self.fileSystem.moveItem(at: sourceURL, to: destinationURL)
                consumedPartIDs.append(part.partID)
            } catch {
                throw TransferSpoolError.partialFileMove(
                    itemID: manifest.itemID,
                    consumedPartIDs: consumedPartIDs,
                    failedPartID: part.partID,
                    detail: String(describing: error)
                )
            }
        }
        return TransferSpoolStageResult(
            item: TransferStoredItem(manifest: stagedManifest, directoryURL: itemDirectory),
            recoveryDiagnostics: prepared.diagnostics
        )
    }

    func commitStagedItem(itemID: UUID) throws -> TransferStoredItem {
        try self.ensureRootDirectories()
        let sourceURL = self.stagingDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        let destinationURL = self.queuedDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        if self.fileSystem.fileExists(atPath: destinationURL.path) {
            throw TransferSpoolError.destinationAlreadyExists(destinationURL.path)
        }
        let manifest = try self.normalizeObserverIngestManifest(
            self.readManifest(in: sourceURL),
            in: sourceURL
        )
        return try self.moveStagedItemToQueued(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            manifest: manifest
        )
    }

    /// Ownership comparison round-trips both manifests through the spool codec,
    /// then ignores fields rewritten by spool/engine state transitions: disk state,
    /// retry deadline, attention, save/start state, app version, and staged byte counts.
    func verifyOwnership(
        expectedManifest: TransferManifest,
        expectedPayloadSourceURLs: [String: URL]
    ) throws -> TransferOwnershipVerdict {
        let name = expectedManifest.itemID.uuidString
        let queued = self.queuedDirectoryURL.appendingPathComponent(name, isDirectory: true)
        let attention = self.attentionDirectoryURL.appendingPathComponent(name, isDirectory: true)
        let staging = self.stagingDirectoryURL.appendingPathComponent(name, isDirectory: true)
        let hasQueued = self.fileSystem.fileExists(atPath: queued.path)
        let hasAttention = self.fileSystem.fileExists(atPath: attention.path)
        let hasStaging = self.fileSystem.fileExists(atPath: staging.path)
        let hasSalvage = try self.hasSalvageItem(named: name)

        if hasQueued && hasAttention {
            return .conflict(.ownerConflict)
        }
        if hasQueued {
            return self.verifyCommittedCandidate(
                at: queued,
                ownedVerdict: .ownedInQueued,
                expectedManifest: expectedManifest,
                expectedPayloadSourceURLs: expectedPayloadSourceURLs
            )
        }
        if hasAttention {
            return self.verifyCommittedCandidate(
                at: attention,
                ownedVerdict: .ownedInAttention,
                expectedManifest: expectedManifest,
                expectedPayloadSourceURLs: expectedPayloadSourceURLs
            )
        }
        if hasStaging { return .stagingOnly }
        if hasSalvage { return .salvageOnly }
        return .notFound
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
        let normalized: TransferManifest
        do {
            normalized = try self.normalizeObserverIngestManifest(item.manifest, in: item.directoryURL)
        } catch {
            transferSpoolLog.error(
                "transfer attention requeue normalization failed \(item.manifest.itemID.uuidString, privacy: .public) \(String(describing: error), privacy: .public)"
            )
            throw error
        }
        var manifest = normalized.replacingDiskState(.queued)
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

    func writeBodyStream(
        for item: TransferStoredItem,
        _ body: (any TransferByteSink) throws -> Void
    ) throws -> (url: URL, byteCount: Int) {
        let url = self.bodyCacheURL(for: item)
        let byteCount = try self.fileSystem.writeStream(to: url, body)
        return (url, byteCount)
    }

    func byteCount(at url: URL) throws -> Int {
        try self.fileSystem.byteCount(at: url)
    }

    func removeBodyCache(for item: TransferStoredItem) {
        try? self.fileSystem.removeItem(at: self.bodyCacheURL(for: item))
    }

    private func removeBodyCacheForNormalization(for item: TransferStoredItem) throws {
        let url = self.bodyCacheURL(for: item)
        guard self.fileSystem.fileExists(atPath: url.path) else { return }
        try self.fileSystem.removeItem(at: url)
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

    func existingPayloadURL(for part: TransferPayloadPartDescriptor, in item: TransferStoredItem) throws -> URL? {
        let url = try self.payloadURL(for: part, in: item.directoryURL)
        guard self.fileSystem.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func payloadByteCount(for part: TransferPayloadPartDescriptor, in item: TransferStoredItem) throws -> Int {
        try self.fileSystem.byteCount(at: self.payloadURL(for: part, in: item.directoryURL))
    }

    private func ensureRootDirectories() throws {
        for url in [
            self.rootURL,
            self.stagingDirectoryURL,
            self.queuedDirectoryURL,
            self.attentionDirectoryURL,
            self.deleteSinkDirectoryURL,
            self.salvageDirectoryURL,
        ] {
            try self.fileSystem.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private struct PreparedStagingDirectory {
        var directoryURL: URL
        var diagnostics: [TransferRecoveryDiagnostic]
    }

    private struct StagedRecoveryResult {
        var promoted: [TransferStoredItem]
        var attention: [TransferStoredItem]
        var diagnostics: [TransferRecoveryDiagnostic]
    }

    private func prepareStagingDirectory(for manifest: TransferManifest) throws -> PreparedStagingDirectory {
        let itemDirectory = self.stagingDirectoryURL.appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
        guard self.fileSystem.fileExists(atPath: itemDirectory.path) else {
            return PreparedStagingDirectory(directoryURL: itemDirectory, diagnostics: [])
        }
        let diagnostic = try self.salvageDirectory(
            itemDirectory,
            reason: "staging_collision",
            manifest: try? self.readManifest(in: itemDirectory)
        )
        return PreparedStagingDirectory(directoryURL: itemDirectory, diagnostics: [diagnostic])
    }

    private func recoverStagedItems(
        knownCommittedItemIDs: Set<UUID>,
        excluding conflictedItemIDs: Set<UUID>,
        now: Date
    ) throws -> StagedRecoveryResult {
        guard self.fileSystem.fileExists(atPath: self.stagingDirectoryURL.path) else {
            return StagedRecoveryResult(promoted: [], attention: [], diagnostics: [])
        }
        var promoted: [TransferStoredItem] = []
        var attention: [TransferStoredItem] = []
        var diagnostics: [TransferRecoveryDiagnostic] = []
        var committedItemIDs = knownCommittedItemIDs
        for url in try self.fileSystem.contentsOfDirectory(at: self.stagingDirectoryURL) {
            if let itemID = UUID(uuidString: url.lastPathComponent), conflictedItemIDs.contains(itemID) {
                continue
            }
            let manifest: TransferManifest
            do {
                manifest = try self.readManifest(in: url).validatedForScan(expectedDiskState: .queued)
                let item = TransferStoredItem(manifest: manifest, directoryURL: url)
                if self.firstMissingDeclaredPayload(in: item) != nil {
                    diagnostics.append(try self.salvageDirectory(url, reason: "incomplete_staging", manifest: manifest))
                    continue
                }
            } catch {
                diagnostics.append(try self.salvageDirectory(url, reason: "incomplete_staging", manifest: nil))
                continue
            }
            let destinationURL = self.queuedDirectoryURL.appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
            let attentionURL = self.attentionDirectoryURL.appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
            if committedItemIDs.contains(manifest.itemID)
                || self.fileSystem.fileExists(atPath: destinationURL.path)
                || self.fileSystem.fileExists(atPath: attentionURL.path) {
                diagnostics.append(try self.salvageDirectory(url, reason: "committed_twin_exists", manifest: manifest))
                continue
            }
            let stagedItem = TransferStoredItem(manifest: manifest, directoryURL: url)
            let normalized: TransferManifest
            do {
                normalized = try self.normalizeObserverIngestManifest(manifest, in: url)
            } catch {
                let detail = "v3 normalization failed: \(String(describing: error))"
                transferSpoolLog.error(
                    "transfer staged normalization failed \(manifest.itemID.uuidString, privacy: .public) \(String(describing: error), privacy: .public)"
                )
                let moved = try self.moveQueuedItemToAttention(
                    stagedItem,
                    reason: "v3_normalization_failed",
                    detail: detail,
                    now: now
                )
                attention.append(moved)
                committedItemIDs.insert(moved.manifest.itemID)
                diagnostics.append(TransferRecoveryDiagnostic(
                    source: manifest.sourceKey,
                    itemID: manifest.itemID,
                    previousState: .staged,
                    nextState: .attention,
                    outcome: .needsAttention,
                    detail: detail
                ))
                continue
            }
            let item = try self.moveStagedItemToQueued(
                sourceURL: url,
                destinationURL: destinationURL,
                manifest: normalized
            )
            committedItemIDs.insert(item.manifest.itemID)
            promoted.append(item)
        }
        return StagedRecoveryResult(promoted: promoted, attention: attention, diagnostics: diagnostics)
    }

    private func moveStagedItemToQueued(
        sourceURL: URL,
        destinationURL: URL,
        manifest: TransferManifest
    ) throws -> TransferStoredItem {
        var manifest = manifest.replacingDiskState(.queued)
        manifest.attention = nil
        try self.fileSystem.moveItem(at: sourceURL, to: destinationURL)
        try self.writeManifestAtomically(manifest, in: destinationURL)
        return TransferStoredItem(manifest: manifest, directoryURL: destinationURL)
    }

    private func salvageDirectory(
        _ sourceURL: URL,
        reason: String,
        manifest: TransferManifest?
    ) throws -> TransferRecoveryDiagnostic {
        let destinationURL = self.salvageDirectoryURL
            .appendingPathComponent(reason, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        try self.fileSystem.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.fileSystem.moveItem(at: sourceURL, to: destinationURL)
        return TransferRecoveryDiagnostic(
            source: manifest?.sourceKey ?? "spool",
            itemID: manifest?.itemID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            previousState: .staged,
            nextState: .salvaged,
            outcome: .salvaged,
            detail: reason
        )
    }

    private func manifestByApplyingByteCounts(
        _ manifest: TransferManifest,
        byteCountsByPartID: [String: Int]
    ) -> TransferManifest {
        var updated = manifest
        updated.payloadParts = manifest.payloadParts.map { part in
            var updatedPart = part
            updatedPart.byteCount = byteCountsByPartID[part.partID]
            return updatedPart
        }
        return updated
    }

    private func scan(state: TransferDiskState, excluding conflictedItemIDs: Set<UUID>) throws -> [TransferStoredItem] {
        let directory = state == .queued ? self.queuedDirectoryURL : self.attentionDirectoryURL
        guard self.fileSystem.fileExists(atPath: directory.path) else { return [] }
        var items: [TransferStoredItem] = []
        for url in try self.fileSystem.contentsOfDirectory(at: directory) {
            if let itemID = UUID(uuidString: url.lastPathComponent), conflictedItemIDs.contains(itemID) {
                continue
            }
            guard var manifest = try? self.readManifest(in: url).validatedForScan(expectedDiskState: state) else { continue }
            if manifest.diskState != state {
                manifest = manifest.replacingDiskState(state)
                if state == .queued {
                    manifest.attention = nil
                }
                try self.writeManifestAtomically(manifest, in: url)
            }
            items.append(TransferStoredItem(manifest: manifest, directoryURL: url))
        }
        return items.sorted {
            if $0.manifest.createdAt == $1.manifest.createdAt {
                return $0.manifest.itemID.uuidString < $1.manifest.itemID.uuidString
            }
            return $0.manifest.createdAt < $1.manifest.createdAt
        }
    }

    private func normalizePersistedObserverIngestItems(
        state: TransferDiskState,
        excluding conflictedItemIDs: Set<UUID>,
        now: Date
    ) throws -> [TransferRecoveryDiagnostic] {
        let directory = state == .queued ? self.queuedDirectoryURL : self.attentionDirectoryURL
        guard self.fileSystem.fileExists(atPath: directory.path) else { return [] }

        var diagnostics: [TransferRecoveryDiagnostic] = []
        for url in try self.fileSystem.contentsOfDirectory(at: directory) {
            guard let itemID = UUID(uuidString: url.lastPathComponent), !conflictedItemIDs.contains(itemID),
                  let manifest = try? self.readManifest(in: url).validatedForScan(expectedDiskState: state),
                  self.isPredecessorObserverIngestManifest(manifest)
            else {
                continue
            }

            let item = TransferStoredItem(manifest: manifest, directoryURL: url)
            do {
                _ = try self.normalizeObserverIngestManifest(manifest, in: url)
            } catch {
                let detail = "v3 normalization failed: \(String(describing: error))"
                if state == .queued {
                    _ = try self.moveQueuedItemToAttention(
                        item,
                        reason: "v3_normalization_failed",
                        detail: detail,
                        now: now
                    )
                }
                diagnostics.append(TransferRecoveryDiagnostic(
                    source: manifest.sourceKey,
                    itemID: manifest.itemID,
                    previousState: state == .queued ? .queued : .attention,
                    nextState: .attention,
                    outcome: .needsAttention,
                    detail: detail
                ))
            }
        }
        return diagnostics
    }

    private func conflictedItemIDs() -> Set<UUID> {
        let queued = self.itemIDs(in: self.queuedDirectoryURL)
        let attention = self.itemIDs(in: self.attentionDirectoryURL)
        return queued.intersection(attention)
    }

    private func itemIDs(in directoryURL: URL) -> Set<UUID> {
        guard let children = try? self.fileSystem.contentsOfDirectory(at: directoryURL) else {
            return []
        }
        return Set(children.compactMap { UUID(uuidString: $0.lastPathComponent) })
    }

    private func firstMissingDeclaredPayload(in item: TransferStoredItem) -> String? {
        for part in item.manifest.payloadParts {
            guard let url = try? self.payloadURL(for: part, in: item.directoryURL),
                  self.fileSystem.fileExists(atPath: url.path)
            else {
                return part.filename
            }
        }
        return nil
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

    private func itemSort(_ lhs: TransferStoredItem, _ rhs: TransferStoredItem) -> Bool {
        if lhs.manifest.createdAt == rhs.manifest.createdAt {
            return lhs.manifest.itemID.uuidString < rhs.manifest.itemID.uuidString
        }
        return lhs.manifest.createdAt < rhs.manifest.createdAt
    }

    private func hasSalvageItem(named name: String) throws -> Bool {
        guard self.fileSystem.fileExists(atPath: self.salvageDirectoryURL.path) else { return false }
        for reason in try self.fileSystem.contentsOfDirectory(at: self.salvageDirectoryURL) {
            for recovery in try self.fileSystem.contentsOfDirectory(at: reason) {
                let candidate = recovery.appendingPathComponent(name, isDirectory: true)
                if self.fileSystem.fileExists(atPath: candidate.path) {
                    return true
                }
            }
        }
        return false
    }

    private func verifyCommittedCandidate(
        at directoryURL: URL,
        ownedVerdict: TransferOwnershipVerdict,
        expectedManifest: TransferManifest,
        expectedPayloadSourceURLs: [String: URL]
    ) -> TransferOwnershipVerdict {
        let candidate: TransferManifest
        do {
            candidate = try self.readManifest(in: directoryURL).validatedForScan()
        } catch {
            return .conflict(.manifestUndecodable)
        }
        guard candidate.itemID == expectedManifest.itemID,
              candidate.source == expectedManifest.source,
              self.manifestsMatchForOwnership(candidate, expectedManifest)
        else {
            return .conflict(.manifestMismatch)
        }
        for part in candidate.payloadParts {
            let payloadURL: URL
            do {
                payloadURL = try self.payloadURL(for: part, in: directoryURL)
                guard self.fileSystem.fileExists(atPath: payloadURL.path),
                      let expectedByteCount = part.byteCount,
                      try self.fileSystem.byteCount(at: payloadURL) == expectedByteCount
                else {
                    return .conflict(.payloadMismatch)
                }
            } catch {
                return .conflict(.payloadUnreadable)
            }
            if let sourceURL = expectedPayloadSourceURLs[part.partID] {
                do {
                    guard try self.digest(at: sourceURL) == self.digest(at: payloadURL) else {
                        return .conflict(.payloadMismatch)
                    }
                } catch {
                    return .conflict(.payloadUnreadable)
                }
            }
        }
        return ownedVerdict
    }

    private func manifestsMatchForOwnership(_ candidate: TransferManifest, _ expected: TransferManifest) -> Bool {
        do {
            let normalizedCandidate = self.normalizedForOwnershipComparison(
                try Self.decoder().decode(TransferManifest.self, from: Self.encoder().encode(candidate))
            )
            let normalizedExpected = self.normalizedForOwnershipComparison(
                try Self.decoder().decode(TransferManifest.self, from: Self.encoder().encode(expected))
            )
            return try Self.encoder().encode(normalizedCandidate) == Self.encoder().encode(normalizedExpected)
        } catch {
            return false
        }
    }

    private func normalizedForOwnershipComparison(_ manifest: TransferManifest) -> TransferManifest {
        var normalized = manifest
        normalized.diskState = .queued
        normalized.nextAttemptAt = nil
        normalized.attention = nil
        normalized.saveThenStart = nil
        normalized.appVersion = nil
        normalized.payloadParts = normalized.payloadParts.map { part in
            var part = part
            part.byteCount = nil
            return part
        }
        return normalized
    }

    private func digest(at url: URL) throws -> SHA256.Digest {
        var hasher = SHA256()
        try self.fileSystem.readChunks(at: url, chunkSize: 64 * 1024) { data in
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

    private nonisolated static let devicesIngestPath = "/app/devices/ingest"

    private func isPredecessorObserverIngestManifest(_ manifest: TransferManifest) -> Bool {
        guard let ingest = manifest.observerIngest else { return false }
        return manifest.endpoint.destinationKind == .observerIngest
            && ingest.ingestProtocolVersion != 3
    }

    private func normalizeObserverIngestManifest(
        _ manifest: TransferManifest,
        in directoryURL: URL
    ) throws -> TransferManifest {
        guard self.isPredecessorObserverIngestManifest(manifest) else { return manifest }
        guard var ingest = manifest.observerIngest else { return manifest }

        let item = TransferStoredItem(manifest: manifest, directoryURL: directoryURL)
        try self.removeBodyCacheForNormalization(for: item)

        ingest.ingestProtocolVersion = 3
        var normalized = manifest
        normalized.endpoint.path = Self.devicesIngestPath
        normalized.observerIngest = ingest
        try self.writeManifestAtomically(normalized, in: directoryURL)
        return normalized
    }

    private func readManifest(in directoryURL: URL) throws -> TransferManifest {
        try Self.decoder().decode(
            TransferManifest.self,
            from: self.fileSystem.data(contentsOf: self.manifestURL(in: directoryURL))
        )
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
