// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import CryptoKit

nonisolated let SF_DATALESS: UInt32 = 0x4000_0000

nonisolated struct ObsidianNoteMetadata: Equatable, Sendable {
    var relativePath: String
    var documentIdentifier: Int?
    var mtimeMs: Int64
    var size: Int64
    var isUnavailable: Bool
}

nonisolated enum ObsidianNoteContent: Equatable, Sendable {
    case sendable(text: String, contentHash: String)
    case tooLarge(bytes: Int64)
    case unavailable
    case readFailed
}

nonisolated struct ObsidianWalkedNote: Equatable, Sendable {
    var relativePath: String
    var documentIdentifier: Int?
    var mtimeMs: Int64
    var size: Int64
    var content: ObsidianNoteContent
}

nonisolated enum ObsidianWalkError: Error, Equatable, Sendable {
    case unreadableRootOrConfig
    case enumerationFailed
    case cancelled
}

nonisolated struct ObsidianWalkSnapshot: Sendable {
    var notes: [ObsidianWalkedNote]
    var unavailableCount: Int
    var tooLargeCount: Int
    var duration: TimeInterval
}

nonisolated struct ObsidianScopedWalk: Sendable {
    var snapshot: ObsidianWalkSnapshot
    var refreshedBookmark: Data?
    var plannedVault: ObsidianVaultState? = nil
}

nonisolated enum ObsidianVaultWalker {
    static func scopedWalk(
        bookmarkData: Data,
        previousTable: [String: (mtimeMs: Int64, size: Int64, contentHash: String, text: String)],
        documentIdentifierProvider: (@Sendable (URL) -> Int?)?
    ) throws -> ObsidianScopedWalk {
        try Task.checkCancellation()
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        guard root.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { root.stopAccessingSecurityScopedResource() }
        var coordinationError: NSError?
        var result: Result<ObsidianScopedWalk, Error>?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .withoutChanges, error: &coordinationError) { accessible in
            result = Result {
                try Task.checkCancellation()
                let snapshot = try Self.walk(rootURL: accessible, previousTable: previousTable,
                    documentIdentifierProvider: documentIdentifierProvider, isCancelled: { Task.isCancelled })
                let refreshed = stale ? try accessible.bookmarkData(options: .minimalBookmark,
                    includingResourceValuesForKeys: nil, relativeTo: nil) : nil
                return ObsidianScopedWalk(snapshot: snapshot, refreshedBookmark: refreshed)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ObsidianWalkError.unreadableRootOrConfig }
        return try result.get()
    }

    /// Walks a vault folder recursively, reading regular markdown notes off the main actor.
    /// - Parameters:
    ///   - rootURL: The resolved security-scoped vault directory URL.
    ///   - previousTable: Map of relativePath -> (mtimeMs, size, contentHash, text) to skip unchanged file reads.
    ///   - isCancelled: Cancellation probe.
    static func walk(
        rootURL: URL,
        previousTable: [String: (mtimeMs: Int64, size: Int64, contentHash: String, text: String)] = [:],
        documentIdentifierProvider: (@Sendable (URL) -> Int?)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ObsidianWalkSnapshot {
        let start = Date()
        guard !isCancelled() else { throw ObsidianWalkError.cancelled }

        let rootPath = rootURL.path
        guard checkDirectoryReadable(path: rootPath),
              checkDirectoryReadable(path: (rootURL.appendingPathComponent(".obsidian")).path)
        else {
            throw ObsidianWalkError.unreadableRootOrConfig
        }

        var notes: [ObsidianWalkedNote] = []
        var unavailableCount = 0
        var tooLargeCount = 0

        try walkDirectory(
            directoryURL: rootURL,
            relativePrefix: "",
            previousTable: previousTable,
            documentIdentifierProvider: documentIdentifierProvider,
            isCancelled: isCancelled,
            notes: &notes,
            unavailableCount: &unavailableCount,
            tooLargeCount: &tooLargeCount
        )

        let duration = Date().timeIntervalSince(start)
        return ObsidianWalkSnapshot(
            notes: notes,
            unavailableCount: unavailableCount,
            tooLargeCount: tooLargeCount,
            duration: duration
        )
    }

    private static func walkDirectory(
        directoryURL: URL,
        relativePrefix: String,
        previousTable: [String: (mtimeMs: Int64, size: Int64, contentHash: String, text: String)],
        documentIdentifierProvider: (@Sendable (URL) -> Int?)?,
        isCancelled: @escaping @Sendable () -> Bool,
        notes: inout [ObsidianWalkedNote],
        unavailableCount: inout Int,
        tooLargeCount: inout Int
    ) throws {
        guard !isCancelled() else { throw ObsidianWalkError.cancelled }

        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .documentIdentifierKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ],
                options: []
            )
        } catch {
            throw ObsidianWalkError.enumerationFailed
        }

        for itemURL in contents {
            guard !isCancelled() else { throw ObsidianWalkError.cancelled }

            let name = itemURL.lastPathComponent
            // Skip dot files and directories starting with "."
            if name.hasPrefix(".") {
                // If it is an iCloud placeholder for a markdown note, e.g. .note.md.icloud
                if name.hasSuffix(".icloud") {
                    let stripped = String(name.dropFirst().dropLast(7))
                    if stripped.lowercased().hasSuffix(".md") {
                        let relPath = relativePrefix.isEmpty ? stripped : "\(relativePrefix)/\(stripped)"
                        if ObsidianWire.isSendablePath(relPath) {
                            unavailableCount += 1
                            notes.append(ObsidianWalkedNote(
                                relativePath: relPath,
                                documentIdentifier: nil,
                                mtimeMs: 0,
                                size: 0,
                                content: .unavailable
                            ))
                        }
                    }
                }
                continue
            }

            // Excluded directory names (templates, _templates in any case)
            let lowerName = name.lowercased()
            if lowerName == "templates" || lowerName == "_templates" {
                continue
            }

            var statBuf = stat()
            guard lstat(itemURL.path, &statBuf) == 0 else {
                throw ObsidianWalkError.enumerationFailed
            }

            // Skip symlinks (an excluded symlink does not fail the scan)
            if (statBuf.st_mode & S_IFMT) == S_IFLNK {
                continue
            }

            if (statBuf.st_mode & S_IFMT) == S_IFDIR {
                let subPrefix = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
                try walkDirectory(
                    directoryURL: itemURL,
                    relativePrefix: subPrefix,
                    previousTable: previousTable,
                    documentIdentifierProvider: documentIdentifierProvider,
                    isCancelled: isCancelled,
                    notes: &notes,
                    unavailableCount: &unavailableCount,
                    tooLargeCount: &tooLargeCount
                )
            } else if (statBuf.st_mode & S_IFMT) == S_IFREG {
                guard name.lowercased().hasSuffix(".md") else { continue }
                let relPath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
                guard ObsidianWire.isSendablePath(relPath) else { continue }

                // Check dataless flag
                let isDataless = (statBuf.st_flags & SF_DATALESS) != 0
                if isDataless {
                    unavailableCount += 1
                    notes.append(ObsidianWalkedNote(
                        relativePath: relPath,
                        documentIdentifier: readDocumentIdentifier(url: itemURL, provider: documentIdentifierProvider),
                        mtimeMs: extractMtimeMs(statBuf),
                        size: Int64(statBuf.st_size),
                        content: .unavailable
                    ))
                    continue
                }

                let docID = readDocumentIdentifier(url: itemURL, provider: documentIdentifierProvider)
                let mtimeMs = extractMtimeMs(statBuf)
                let sizeBytes = Int64(statBuf.st_size)

                // Check size limit (max 4 MiB)
                if sizeBytes > Int64(ObsidianWire.maxNoteBytes) {
                    tooLargeCount += 1
                    notes.append(ObsidianWalkedNote(
                        relativePath: relPath,
                        documentIdentifier: docID,
                        mtimeMs: mtimeMs,
                        size: sizeBytes,
                        content: .tooLarge(bytes: sizeBytes)
                    ))
                    continue
                }

                // Optimization: unchanged mtime in milliseconds and size skip the content read
                if let existing = previousTable[relPath],
                   existing.mtimeMs == mtimeMs,
                   existing.size == sizeBytes
                {
                    notes.append(ObsidianWalkedNote(
                        relativePath: relPath,
                        documentIdentifier: docID,
                        mtimeMs: mtimeMs,
                        size: sizeBytes,
                        content: .sendable(text: existing.text, contentHash: existing.contentHash)
                    ))
                    continue
                }

                // Read file content (up to maxNoteBytes + 1)
                let content = readNoteContent(at: itemURL, expectedSize: sizeBytes, expectedMtime: mtimeMs)
                switch content {
                case .tooLarge(let bytes):
                    tooLargeCount += 1
                    notes.append(ObsidianWalkedNote(
                        relativePath: relPath,
                        documentIdentifier: docID,
                        mtimeMs: mtimeMs,
                        size: bytes,
                        content: .tooLarge(bytes: bytes)
                    ))
                default:
                    notes.append(ObsidianWalkedNote(
                        relativePath: relPath,
                        documentIdentifier: docID,
                        mtimeMs: mtimeMs,
                        size: sizeBytes,
                        content: content
                    ))
                }
            }
        }
    }

    private static func checkDirectoryReadable(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard let dir = opendir(path) else { return false }
        closedir(dir)
        return true
    }

    static func readDocumentIdentifier(url: URL, provider: (@Sendable (URL) -> Int?)? = nil) -> Int? {
        if let provider, let id = provider(url) {
            return id
        }
        if let values = try? url.resourceValues(forKeys: [.documentIdentifierKey]),
           let id = values.documentIdentifier {
            return id
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(truncatingIfNeeded: info.st_ino)
    }

    private static func extractMtimeMs(_ statBuf: stat) -> Int64 {
        Int64(statBuf.st_mtimespec.tv_sec) * 1000 + Int64(statBuf.st_mtimespec.tv_nsec) / 1_000_000
    }

    private static func readNoteContent(at url: URL, expectedSize: Int64, expectedMtime: Int64) -> ObsidianNoteContent {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .readFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG,
              Int64(initial.st_size) == expectedSize, extractMtimeMs(initial) == expectedMtime else { return .readFailed }

        do {
            let limit = ObsidianWire.maxNoteBytes + 1
            var data = Data()
            while data.count < limit {
                guard let chunk = try handle.read(upToCount: min(64 * 1024, limit - data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard Int64(data.count) == expectedSize || data.count > ObsidianWire.maxNoteBytes else { return .readFailed }
            var final = stat()
            guard fstat(descriptor, &final) == 0,
                  initial.st_size == final.st_size, extractMtimeMs(initial) == extractMtimeMs(final) else { return .readFailed }
            if data.count > ObsidianWire.maxNoteBytes {
                return .tooLarge(bytes: Int64(data.count))
            }
            let text = String(decoding: data, as: UTF8.self)
            if text.utf8.count > ObsidianWire.maxNoteBytes {
                return .tooLarge(bytes: Int64(text.utf8.count))
            }
            let contentHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            return .sendable(text: text, contentHash: contentHash)
        } catch {
            return .readFailed
        }
    }
}
