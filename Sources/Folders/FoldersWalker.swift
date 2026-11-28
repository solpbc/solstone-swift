// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// One regular file discovered during a recursive folder walk.
nonisolated struct FolderWalkedFile: Equatable, Sendable {
    var relPath: String
    var identity: FolderFileIdentity?
    var sizeBytes: UInt64
    var mtimeMs: Int64
    var metadata: FolderPlatformMetadata
    var isScreenshot: Bool
}

/// Result of a complete or partial recursive walk of one folder.
nonisolated struct FolderWalkOutcome: Equatable, Sendable {
    var files: [FolderWalkedFile]
    var unreadable: Int
    var deferredPartials: Int
    var placeholdersSkipped: Int
    var deferredPaths: Set<String> = []
    /// Deletion & rename reconciliation only runs when `complete == true`.
    var complete: Bool
    var refreshedBookmark: Data?
}

/// Errors produced when attempting to inspect or walk a chosen folder.
nonisolated enum FolderWalkError: Error, Equatable, Sendable {
    case bookmarkInvalid
    case missing
    case refusedLocal
    case refusedProvider
    case cancelled
}

/// Result of probing a newly picked URL before adding it to the folder ledger.
nonisolated struct FolderProbeResult: Equatable, Sendable {
    var name: String
    var displayLabel: String
    var canonicalPath: String
    var bookmarkData: Data?
    var isCloudProvider: Bool
}

/// Filesystem abstraction enabling deterministic unit tests and off-main-actor live I/O.
nonisolated protocol FolderFileSystem: Sendable {
    func probePickedFolder(url: URL) throws -> FolderProbeResult
    func walk(bookmarkData: Data?, fallbackPath: String, isCloudProvider: Bool) throws -> FolderWalkOutcome
    func readFile(bookmarkData: Data?, fallbackPath: String, relPath: String, maxBytes: UInt64) throws -> Data?
    func fileExists(bookmarkData: Data?, fallbackPath: String, relPath: String) -> Bool
    func fileMetadata(bookmarkData: Data?, fallbackPath: String, relPath: String) -> FolderPlatformMetadata?
}

/// Live iOS/iPadOS filesystem adapter using security-scoped bookmarks,
/// `NSFileCoordinator(.withoutChanges)`, non-hydrating iCloud placeholder detection
/// (`SF_DATALESS`, `.icloud` stubs, `ubiquitousItemDownloadingStatusKey`),
/// symlink root confinement, and POSIX `getxattr` download metadata.
nonisolated final class LiveFolderFileSystem: FolderFileSystem, Sendable {
    private static let sfDataless: UInt32 = 0x4000_0000

    init() {}

    func probePickedFolder(url: URL) throws -> FolderProbeResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let isCloud = Self.detectCloudProvider(url: url)

        var coordError: NSError?
        var probeResult: Result<FolderProbeResult, Error> = .failure(
            isCloud ? FolderWalkError.refusedProvider : FolderWalkError.refusedLocal
        )

        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { accessible in
            probeResult = Result {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: accessible.path, isDirectory: &isDir),
                      isDir.boolValue
                else {
                    throw isCloud ? FolderWalkError.refusedProvider : FolderWalkError.refusedLocal
                }
                // Prove directory listing succeeds; never fake an empty folder if the storage app refuses.
                do {
                    _ = try FileManager.default.contentsOfDirectory(
                        at: accessible,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: []
                    )
                } catch {
                    throw Self.classifyRefusal(error: error, isCloudProvider: isCloud)
                }

                let canonical = Self.canonicalPath(of: accessible)
                let name = FoldersClassifier.sanitizedFolderName(accessible.lastPathComponent)
                let label = FoldersClassifier.displayLabel(for: accessible, isCloudProvider: isCloud)
                let bookmark = try? accessible.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                return FolderProbeResult(
                    name: name,
                    displayLabel: label,
                    canonicalPath: canonical,
                    bookmarkData: bookmark,
                    isCloudProvider: isCloud
                )
            }
        }

        if let coordError {
            throw Self.classifyRefusal(error: coordError, isCloudProvider: isCloud)
        }
        return try probeResult.get()
    }

    func walk(bookmarkData: Data?, fallbackPath: String, isCloudProvider: Bool) throws -> FolderWalkOutcome {
        try Task.checkCancellation()
        return try self.withResolvedRoot(
            bookmarkData: bookmarkData,
            fallbackPath: fallbackPath,
            isCloudProvider: isCloudProvider
        ) { accessible, refreshedBookmark in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: accessible.path, isDirectory: &isDir),
                  isDir.boolValue
            else {
                throw FolderWalkError.missing
            }
            let canonicalRoot = Self.canonicalPath(of: accessible)
            var outcome = FolderWalkOutcome(
                files: [],
                unreadable: 0,
                deferredPartials: 0,
                placeholdersSkipped: 0,
                complete: true,
                refreshedBookmark: refreshedBookmark
            )
            var stack: [(URL, String)] = [(accessible, "")]
            var visitedDirs: Set<String> = [canonicalRoot]

            while let (dirURL, prefix) = stack.popLast() {
                try Task.checkCancellation()
                let children: [URL]
                do {
                    children = try FileManager.default.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey,
                            .isSymbolicLinkKey,
                            .fileSizeKey,
                            .contentModificationDateKey,
                            .creationDateKey,
                            .documentIdentifierKey,
                            .isUbiquitousItemKey,
                            .ubiquitousItemDownloadingStatusKey,
                        ],
                        options: []
                    )
                } catch {
                    if prefix.isEmpty {
                        throw Self.classifyRefusal(error: error, isCloudProvider: isCloudProvider)
                    }
                    outcome.unreadable += 1
                    outcome.complete = false
                    continue
                }

                for entryURL in children {
                    try Task.checkCancellation()
                    let name = entryURL.lastPathComponent
                    let relPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
                    if FoldersClassifier.isICloudStubName(name) {
                        let original = String(name.dropFirst().dropLast(".icloud".count))
                        outcome.deferredPaths.insert(prefix.isEmpty ? original : "\(prefix)/\(original)")
                        outcome.placeholdersSkipped += 1
                        continue
                    }
                    if FoldersClassifier.isJunkEntry(name) {
                        continue
                    }
                    if FoldersClassifier.isPartialDownload(name) {
                        outcome.deferredPartials += 1
                        continue
                    }

                    // Non-hydrating lstat check BEFORE opening or touching file contents.
                    var lstatBuf = stat()
                    guard lstat(entryURL.path, &lstatBuf) == 0 else {
                        outcome.unreadable += 1
                        outcome.complete = false
                        continue
                    }
                    if (lstatBuf.st_flags & Self.sfDataless) != 0 {
                        outcome.deferredPaths.insert(relPath)
                        outcome.placeholdersSkipped += 1
                        continue
                    }

                    let isSymlink = (lstatBuf.st_mode & S_IFMT) == S_IFLNK
                    if isSymlink {
                        let resolved = Self.canonicalPath(of: entryURL)
                        guard Self.isPath(resolved, confinedUnder: canonicalRoot) else {
                            continue
                        }
                    }

                    // Check ubiquitous downloading status WITHOUT initiating download.
                    if let values = try? entryURL.resourceValues(forKeys: [
                        .isUbiquitousItemKey,
                        .ubiquitousItemDownloadingStatusKey,
                    ]), values.isUbiquitousItem == true {
                        if values.ubiquitousItemDownloadingStatus != .current {
                            outcome.deferredPaths.insert(relPath)
                            outcome.placeholdersSkipped += 1
                            continue
                        }
                    }

                    var statBuf = stat()
                    guard stat(entryURL.path, &statBuf) == 0 else {
                        outcome.unreadable += 1
                        outcome.complete = false
                        continue
                    }
                    if (statBuf.st_flags & Self.sfDataless) != 0 {
                        outcome.deferredPaths.insert(relPath)
                        outcome.placeholdersSkipped += 1
                        continue
                    }

                    guard FoldersClassifier.isValidRelativePath(relPath) else {
                        continue
                    }

                    let fileType = statBuf.st_mode & S_IFMT
                    if fileType == S_IFDIR {
                        let canonDir = Self.canonicalPath(of: entryURL)
                        let normRoot = FoldersClassifier.normalizedComparablePath(canonicalRoot)
                        let normDir = FoldersClassifier.normalizedComparablePath(canonDir)
                        if (normDir == normRoot || normDir.hasPrefix(normRoot + "/")),
                           visitedDirs.insert(canonDir).inserted
                        {
                            stack.append((entryURL, relPath))
                        }
                        continue
                    }

                    guard fileType == S_IFREG else {
                        continue
                    }

                    let values = try? entryURL.resourceValues(forKeys: [
                        .documentIdentifierKey,
                        .contentModificationDateKey,
                        .creationDateKey,
                    ])
                    let docID: UInt64? = values?.documentIdentifier.flatMap { $0 > 0 ? UInt64($0) : nil }
                    let identity = FolderFileIdentity(
                        documentIdentifier: docID,
                        device: UInt64(bitPattern: Int64(statBuf.st_dev)),
                        inode: UInt64(statBuf.st_ino)
                    )
                    let sizeBytes = UInt64(max(0, statBuf.st_size))
                    let mtimeMs = Self.statMtimeMs(statBuf, fallback: values?.contentModificationDate)
                    let createdMs = values?.creationDate.map { Int64(($0.timeIntervalSince1970 * 1_000.0).rounded(.towardZero)) }
                    let ext = FoldersClassifier.extensionLower(for: name)
                    let platformMeta = Self.collectMetadata(
                        at: entryURL, root: canonicalRoot,
                        sizeBytes: sizeBytes,
                        modifiedMs: mtimeMs,
                        createdMs: createdMs,
                        extensionLower: ext
                    )

                    let isImageExt = ext.map {
                        FolderSupportedList.default.acceptedImageExtensions.contains($0)
                            || FolderSupportedList.default.convertibleImageExtensions.contains($0)
                    } ?? false
                    let isScreenshot = isImageExt ? FoldersImageSupport.isScreenshotImage(at: entryURL) : false

                    outcome.files.append(FolderWalkedFile(
                        relPath: relPath,
                        identity: identity,
                        sizeBytes: sizeBytes,
                        mtimeMs: mtimeMs,
                        metadata: platformMeta,
                        isScreenshot: isScreenshot
                    ))
                }
            }
            return outcome
        }
    }

    func readFile(bookmarkData: Data?, fallbackPath: String, relPath: String, maxBytes: UInt64) throws -> Data? {
        guard FoldersClassifier.isValidRelativePath(relPath) else { return nil }
        return try self.withResolvedRoot(
            bookmarkData: bookmarkData,
            fallbackPath: fallbackPath,
            isCloudProvider: false
        ) { accessible, _ in
            let fileURL = accessible.appendingPathComponent(relPath, isDirectory: false)
            guard Self.isParentConfined(fileURL: fileURL, underRoot: accessible) else { return nil }
            return Self.readLocalNonHydrating(at: fileURL, under: Self.canonicalPath(of: accessible), maxBytes: maxBytes)
        }
    }

    func fileExists(bookmarkData: Data?, fallbackPath: String, relPath: String) -> Bool {
        guard FoldersClassifier.isValidRelativePath(relPath) else { return false }
        let exists = try? self.withResolvedRoot(
            bookmarkData: bookmarkData,
            fallbackPath: fallbackPath,
            isCloudProvider: false
        ) { accessible, _ -> Bool in
            let fileURL = accessible.appendingPathComponent(relPath, isDirectory: false)
            guard Self.isParentConfined(fileURL: fileURL, underRoot: accessible) else { return false }
            var st = stat()
            guard lstat(fileURL.path, &st) == 0 else { return false }
            if (st.st_flags & Self.sfDataless) != 0 { return false }
            return (st.st_mode & S_IFMT) == S_IFREG
        }
        return exists ?? false
    }

    func fileMetadata(bookmarkData: Data?, fallbackPath: String, relPath: String) -> FolderPlatformMetadata? {
        guard FoldersClassifier.isValidRelativePath(relPath) else { return nil }
        return try? self.withResolvedRoot(
            bookmarkData: bookmarkData,
            fallbackPath: fallbackPath,
            isCloudProvider: false
        ) { accessible, _ -> FolderPlatformMetadata? in
            let fileURL = accessible.appendingPathComponent(relPath, isDirectory: false)
            guard Self.isParentConfined(fileURL: fileURL, underRoot: accessible) else { return nil }
            var st = stat()
            guard lstat(fileURL.path, &st) == 0,
                  (st.st_flags & Self.sfDataless) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG
            else { return nil }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let mtimeMs = Self.statMtimeMs(st, fallback: values?.contentModificationDate)
            let createdMs = values?.creationDate.map { Int64(($0.timeIntervalSince1970 * 1_000.0).rounded(.towardZero)) }
            let ext = FoldersClassifier.extensionLower(for: fileURL.lastPathComponent)
            return Self.collectMetadata(
                at: fileURL, root: Self.canonicalPath(of: accessible),
                sizeBytes: UInt64(max(0, st.st_size)),
                modifiedMs: mtimeMs,
                createdMs: createdMs,
                extensionLower: ext
            )
        }
    }

    // MARK: - Internal helpers

    private func withResolvedRoot<T>(
        bookmarkData: Data?,
        fallbackPath: String,
        isCloudProvider: Bool,
        body: (URL, Data?) throws -> T
    ) throws -> T {
        let rootURL: URL
        var stale = false
        if let bookmarkData {
            do {
                rootURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI, .withoutImplicitStartAccessing],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            } catch {
                throw FolderWalkError.bookmarkInvalid
            }
        } else {
            rootURL = URL(fileURLWithPath: fallbackPath, isDirectory: true)
        }

        let accessed = rootURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        var coordError: NSError?
        var innerResult: Result<T, Error> = .failure(FolderWalkError.bookmarkInvalid)
        NSFileCoordinator().coordinate(readingItemAt: rootURL, options: .withoutChanges, error: &coordError) { accessible in
            innerResult = Result {
                try Task.checkCancellation()
                // Eviction after a successful metadata probe must never trigger a download.
                let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
                let scope = IOPOL_SCOPE_THREAD
                let previous = getiopolicy_np(type, scope)
                guard previous >= 0, setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
                    throw FolderWalkError.refusedProvider
                }
                defer { _ = setiopolicy_np(type, scope, previous) }
                let refreshed: Data? = stale ? (try? accessible.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )) : nil
                return try body(accessible, refreshed)
            }
        }
        if let coordError {
            throw Self.classifyRefusal(error: coordError, isCloudProvider: isCloudProvider)
        }
        return try innerResult.get()
    }

    private static func readLocalNonHydrating(at url: URL, under root: String, maxBytes: UInt64) -> Data? {
        var lstatBuf = stat()
        guard lstat(url.path, &lstatBuf) == 0 else { return nil }
        if (lstatBuf.st_flags & Self.sfDataless) != 0 { return nil }
        if (lstatBuf.st_mode & S_IFMT) == S_IFLNK { return nil }

        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current
        {
            return nil
        }

        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        guard Self.isPath(String(cString: resolved), confinedUnder: root) else { return nil }
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              (st.st_flags & Self.sfDataless) == 0,
              st.st_size >= 0,
              UInt64(st.st_size) <= maxBytes
        else { return nil }

        let expected = Int(st.st_size)
        var data = Data()
        data.reserveCapacity(min(expected, 1_048_576))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                if UInt64(data.count + n) > maxBytes {
                    return nil
                }
                data.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        var finalStat = stat()
        guard fstat(fd, &finalStat) == 0, finalStat.st_size == st.st_size,
              finalStat.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec,
              finalStat.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec,
              finalStat.st_nlink > 0, data.count == expected else { return nil }
        return data
    }

    private static func statMtimeMs(_ st: stat, fallback: Date?) -> Int64 {
        let sec = Int64(st.st_mtimespec.tv_sec)
        let nsec = Int64(st.st_mtimespec.tv_nsec)
        if sec > 0 {
            return sec * 1_000 + nsec / 1_000_000
        }
        if let fallback {
            return Int64((fallback.timeIntervalSince1970 * 1_000.0).rounded(.towardZero))
        }
        return 0
    }

    private static func isPath(_ candidateCanonical: String, confinedUnder rootCanonical: String) -> Bool {
        let normRoot = FoldersClassifier.normalizedComparablePath(rootCanonical)
        let normCandidate = FoldersClassifier.normalizedComparablePath(candidateCanonical)
        return normCandidate == normRoot || normCandidate.hasPrefix(normRoot + "/")
    }

    private static func isParentConfined(fileURL: URL, underRoot rootURL: URL) -> Bool {
        let rootCanonical = Self.canonicalPath(of: rootURL)
        let parentCanonical = Self.canonicalPath(of: fileURL.deletingLastPathComponent())
        return Self.isPath(parentCanonical, confinedUnder: rootCanonical)
    }

    private static func canonicalPath(of url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        if let values = try? url.resourceValues(forKeys: [.canonicalPathKey]),
           let canon = values.canonicalPath, !canon.isEmpty
        {
            return canon
        }
        return url.standardizedFileURL.path
    }

    static func detectCloudProvider(url: URL) -> Bool {
        let lower = url.path.lowercased()
        if lower.contains("file provider storage")
            || lower.contains("livefiles")
            || lower.contains("mobile documents")
            || lower.contains("com~apple~clouddocs")
        {
            return true
        }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]) {
            if values.isUbiquitousItem == true { return true }
            if values.volumeIsLocal == false { return true }
        }
        return false
    }

    private static func classifyRefusal(error: Error, isCloudProvider: Bool) -> FolderWalkError {
        if error is CancellationError {
            return .cancelled
        }
        if let walkError = error as? FolderWalkError {
            return walkError
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return .missing
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
            return .missing
        }
        if isCloudProvider || nsError.domain == "NSFileProviderErrorDomain" {
            return .refusedProvider
        }
        return .refusedLocal
    }

    /// Best-effort read of macOS/iOS download origin extended attributes (`kMDItemWhereFroms` and `com.apple.quarantine`).
    static func collectMetadata(
        at url: URL, root: String,
        sizeBytes: UInt64,
        modifiedMs: Int64,
        createdMs: Int64?,
        extensionLower: String?
    ) -> FolderPlatformMetadata {
        var meta = FolderPlatformMetadata(
            sizeBytes: sizeBytes,
            modifiedMs: modifiedMs,
            createdMs: createdMs,
            extensionLower: extensionLower
        )

        guard let resolved = realpath(url.path, nil) else { return meta }
        defer { free(resolved) }
        guard Self.isPath(String(cString: resolved), confinedUnder: root) else { return meta }
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return meta }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
              (opened.st_flags & Self.sfDataless) == 0 else { return meta }

        if let rawWhere = Self.readXattr(fd: fd, name: "com.apple.metadata:kMDItemWhereFroms"),
           let plist = try? PropertyListSerialization.propertyList(from: rawWhere, options: [], format: nil) as? [String]
        {
            let cleaned = plist
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(16)
            if !cleaned.isEmpty {
                let list = Array(cleaned)
                meta.whereFroms = list
                meta.originURL = list.first
                if list.count > 1 {
                    meta.referrerURL = list[1]
                }
            }
        }

        if let rawQuarantine = Self.readXattr(fd: fd, name: "com.apple.quarantine"),
           let text = String(data: rawQuarantine, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            meta.quarantine = String(text.prefix(512))
            let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            if parts.count >= 3 {
                let agent = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !agent.isEmpty {
                    meta.downloadedBy = String(agent.prefix(128))
                }
            }
        }

        return meta
    }

    private static func readXattr(fd: Int32, name: String) -> Data? {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        guard size > 0, size <= 16_384 else { return nil }
        var data = Data(count: size)
        let readCount = data.withUnsafeMutableBytes { buf in
            fgetxattr(fd, name, buf.baseAddress, size, 0, 0)
        }
        guard readCount > 0 else { return nil }
        if readCount < size {
            data.removeSubrange(readCount..<size)
        }
        return data
    }
}
