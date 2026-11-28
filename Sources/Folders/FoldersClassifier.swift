// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Deterministic file sorting, partial-download / junk filtering, text triage,
/// note net-diff checking, overlap detection, and folder ID generation.
nonisolated enum FoldersClassifier {
    private static let partialSuffixes: [String] = [
        ".crdownload",
        ".part",
        ".download",
        ".opdownload",
        ".filepart",
        ".tmp",
    ]

    private static let junkNames: Set<String> = [
        "thumbs.db",
        "desktop.ini",
        "ehthumbs.db",
        ".ds_store",
    ]

    /// Whether a filename is an evicted iCloud Drive placeholder stub (`.<name>.icloud`).
    static func isICloudStubName(_ fileName: String) -> Bool {
        fileName.hasPrefix(".") && fileName.lowercased().hasSuffix(".icloud") && fileName.count > 7
    }

    /// Whether a filename looks like an in-progress download or temporary save that must wait.
    static func isPartialDownload(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return Self.partialSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Whether a directory entry is a hidden dot entry, OS metadata junk, or a temporary lock file.
    static func isJunkEntry(_ fileName: String) -> Bool {
        if fileName.hasPrefix(".") || fileName.hasPrefix("~$") || fileName.hasSuffix("~") {
            return true
        }
        return Self.junkNames.contains(fileName.lowercased())
    }

    /// Extract lowercase extension without leading dot, if any.
    static func extensionLower(for fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// Decode UTF-8 or UTF-16 (with BOM) text bytes; returns nil if invalid or containing UTF-8 NUL bytes.
    static func decodeText(_ bytes: Data) -> String? {
        if bytes.count >= 2 {
            let b0 = bytes[bytes.startIndex]
            let b1 = bytes[bytes.index(after: bytes.startIndex)]
            if b0 == 0xFF, b1 == 0xFE {
                return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian)
            }
            if b0 == 0xFE, b1 == 0xFF {
                return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian)
            }
        }
        if bytes.contains(0x00) {
            return nil
        }
        return String(data: bytes, encoding: .utf8)
    }

    /// Whether a `.md`/`.txt`/`.log` file crosses triage ruleset 8's document threshold
    /// (`long_prose`: >= 5,000 words with >= 70% prose; `structured_prose`: >= 1,500 words
    /// with >= 70% prose and >= 2 heading levels) or exceeds `maxNoteBytes`.
    static func classifyTextFile(_ bytes: Data, supported: FolderSupportedList) -> FolderFileKind {
        if UInt64(bytes.count) > supported.maxNoteBytes {
            return .document
        }
        guard let text = Self.decodeText(bytes) else {
            return .other
        }
        var totalWords = 0
        var proseLines = 0
        var nonEmptyLines = 0
        var headingLevels = Set<Int>()
        var inFence = false

        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                return
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                nonEmptyLines += 1
                return
            }
            nonEmptyLines += 1
            if inFence {
                return
            }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes),
               line.count > hashes,
               line[line.index(line.startIndex, offsetBy: hashes)] == " "
            {
                headingLevels.insert(hashes)
                let rest = line[line.index(line.startIndex, offsetBy: hashes + 1)...]
                totalWords += Self.wordCount(rest)
                proseLines += 1
                return
            }
            let words = Self.wordCount(line[...])
            totalWords += words
            let isListOrTable = line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("|")
                || line.hasPrefix("> ")
            if !isListOrTable || words >= 6 {
                proseLines += 1
            }
        }

        let proseOK = nonEmptyLines > 0 && proseLines * 100 >= nonEmptyLines * 70
        let longProse = proseOK && totalWords >= supported.noteLongWords
        let structuredProse = proseOK
            && totalWords >= supported.noteStructuredWords
            && headingLevels.count >= supported.noteHeadingLevels
        return (longProse || structuredProse) ? .document : .note
    }

    private static func wordCount(_ slice: Substring) -> Int {
        var count = 0
        var inWord = false
        for scalar in slice.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// Deterministic sorting table matching the protocol-v3 contract.
    static func classifyFile(
        extensionLower: String?,
        sizeBytes: UInt64,
        isScreenshot: Bool,
        noteBytes: Data?,
        kinds: FolderKinds,
        supported: FolderSupportedList
    ) -> (FolderFileKind, FolderDeliveryMode) {
        let ext = extensionLower?.lowercased() ?? ""
        let isImage = supported.acceptedImageExtensions.contains(ext)
            || supported.convertibleImageExtensions.contains(ext)

        let fileKind: FolderFileKind
        if isScreenshot && isImage {
            fileKind = .screenshot
        } else if supported.noteExtensions.contains(ext) {
            if sizeBytes > supported.maxNoteBytes {
                fileKind = .document
            } else if let noteBytes {
                fileKind = Self.classifyTextFile(noteBytes, supported: supported)
            } else {
                fileKind = .note
            }
        } else if supported.documentExtensions.contains(ext) {
            fileKind = .document
        } else if supported.transcriptExtensions.contains(ext) {
            fileKind = .transcript
        } else if isImage {
            fileKind = .photo
        } else {
            fileKind = .other
        }

        let withinSize = sizeBytes <= supported.maxContentBytes
        let delivery: FolderDeliveryMode
        if fileKind == .other {
            delivery = kinds.other ? .metadataOnly : .ignore
        } else if kinds.isEnabled(for: fileKind) && withinSize {
            delivery = .content
        } else if kinds.other {
            delivery = .metadataOnly
        } else {
            delivery = .ignore
        }
        return (fileKind, delivery)
    }

    /// Whether a file's extension makes it a note candidate needing text inspection.
    static func isNoteCandidate(extensionLower: String?, supported: FolderSupportedList) -> Bool {
        guard let ext = extensionLower?.lowercased() else { return false }
        return supported.noteExtensions.contains(ext)
    }

    /// Whether a relative path is safe and valid under the protocol-v3 contract.
    static func isValidRelativePath(_ relPath: String) -> Bool {
        guard !relPath.isEmpty,
              relPath.utf8.count <= FolderConstants.maxRelativePathBytes,
              !relPath.hasPrefix("/"),
              !relPath.hasSuffix("/"),
              !relPath.contains("\\")
        else { return false }
        for scalar in relPath.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            return false
        }
        for component in relPath.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." {
                return false
            }
        }
        return true
    }

    /// Normalize a canonical path for overlap comparisons (strips trailing slash and leading `/private`).
    static func normalizedComparablePath(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        if normalized.hasPrefix("/private/var/") {
            normalized = String(normalized.dropFirst("/private".count))
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Whether two paths are equal or one is an ancestor of the other.
    static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        let lhs = Self.normalizedComparablePath(a)
        let rhs = Self.normalizedComparablePath(b)
        if lhs == rhs { return true }
        return lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    /// Overlap check against already-configured folders and an Obsidian vault.
    enum OverlapOutcome: Equatable, Sendable {
        case none
        case alreadyAdded(id: String, name: String)
        case overlap(FolderOverlapTarget)
    }

    static func detectOverlap(
        candidateCanonicalPath: String,
        obsidianVault: (canonicalPath: String, name: String)?,
        existingFolders: [(id: String, canonicalPath: String, name: String)]
    ) -> OverlapOutcome {
        let candidate = Self.normalizedComparablePath(candidateCanonicalPath)
        for existing in existingFolders {
            let norm = Self.normalizedComparablePath(existing.canonicalPath)
            if candidate == norm {
                return .alreadyAdded(id: existing.id, name: existing.name)
            }
            if Self.pathsOverlap(candidate, norm) {
                return .overlap(.folder(id: existing.id, name: existing.name))
            }
        }
        if let obsidianVault, Self.pathsOverlap(candidate, obsidianVault.canonicalPath) {
            return .overlap(.obsidian(name: obsidianVault.name))
        }
        return .none
    }

    /// Build a deterministic client-assigned folder ID matching `^[a-z0-9][a-z0-9_-]{0,63}$`.
    static func makeFolderID(name: String, canonicalPath: String) -> String {
        let hash = String(folderSHA256Hex(Data(Self.normalizedComparablePath(canonicalPath).utf8)).prefix(8))
        var slug = ""
        var lastDash = false
        for scalar in name.unicodeScalars {
            if (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            {
                slug.append(Character(scalar).lowercased())
                lastDash = false
            } else if (scalar == "-" || scalar == "_" || scalar == " ") && !slug.isEmpty && !lastDash {
                slug.append("-")
                lastDash = true
            }
            if slug.count >= 40 { break }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "folder-\(hash)" : "\(trimmed)-\(hash)"
    }

    /// Bounded LCS net line diff between `before` and `after`.
    /// Returns `nil` when lines are unchanged (e.g. an edit reverted before the window closed).
    static func netLineDiff(before: String, after: String) -> String? {
        if before == after { return nil }
        let oldLines = Self.splitLines(before)
        let newLines = Self.splitLines(after)

        var prefix = 0
        while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > prefix && newEnd > prefix && oldLines[oldEnd - 1] == newLines[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        let oldMid = Array(oldLines[prefix..<oldEnd])
        let newMid = Array(newLines[prefix..<newEnd])
        if oldMid.isEmpty && newMid.isEmpty {
            return nil
        }

        var out = ""
        let (lcsCells, lcsOverflow) = oldMid.count.multipliedReportingOverflow(by: newMid.count)
        if !lcsOverflow && lcsCells <= 64_000 {
            let m = oldMid.count
            let n = newMid.count
            var dp = [Int](repeating: 0, count: (m + 1) * (n + 1))
            let rowStride = n + 1
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if oldMid[i] == newMid[j] {
                        dp[i * rowStride + j] = dp[(i + 1) * rowStride + (j + 1)] + 1
                    } else {
                        dp[i * rowStride + j] = max(dp[(i + 1) * rowStride + j], dp[i * rowStride + (j + 1)])
                    }
                }
            }
            var i = 0
            var j = 0
            while i < m && j < n {
                if oldMid[i] == newMid[j] {
                    i += 1
                    j += 1
                } else if dp[(i + 1) * rowStride + j] >= dp[i * rowStride + (j + 1)] {
                    out += "- \(oldMid[i])\n"
                    i += 1
                } else {
                    out += "+ \(newMid[j])\n"
                    j += 1
                }
            }
            while i < m {
                out += "- \(oldMid[i])\n"
                i += 1
            }
            while j < n {
                out += "+ \(newMid[j])\n"
                j += 1
            }
        } else {
            for line in oldMid { out += "- \(line)\n" }
            for line in newMid { out += "+ \(line)\n" }
        }
        return out.isEmpty ? nil : out
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        text.enumerateLines { line, _ in
            lines.append(line)
        }
        return lines
    }

    /// Friendly folder location label for facts and accessibility.
    static func displayLabel(for url: URL, isCloudProvider: Bool) -> String {
        let name = url.lastPathComponent
        if isCloudProvider {
            let lower = url.path.lowercased()
            if lower.contains("mobile documents") || lower.contains("com~apple~clouddocs") {
                return "iCloud Drive › \(name)"
            }
        }
        return name.isEmpty ? url.path : name
    }

    /// Ensure folder display name conforms to protocol-v3 bounds (`1..=128` UTF-8 bytes, no control chars).
    static func sanitizedFolderName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .map(Character.init)
        var text = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = "Folder"
        }
        while text.utf8.count > 128, !text.isEmpty {
            text.removeLast()
        }
        return text.isEmpty ? "Folder" : text
    }
}
