// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct ObsidianPackedWindows: Sendable {
    var vault: ObsidianVaultState
    var changed: Bool
}

nonisolated enum ObsidianWindowPacker {
    static func pack(_ original: ObsidianVaultState, now: Date, directory: URL) throws -> ObsidianPackedWindows {
        var vault = original
        let grouped = Dictionary(grouping: vault.pendingChanges, by: groupKey)
        let pathsByID = Dictionary(uniqueKeysWithValues: vault.table.map { ($0.value.logicalID, $0.key) })
        var closed = Set<String>()
        for key in grouped.keys.sorted() {
            try Task.checkCancellation()
            guard let changes = grouped[key], let first = changes.first,
                  now >= first.changedAt.date.addingTimeInterval(TimeInterval(first.changedAt.closeEpochSeconds - first.changedAt.epochSeconds)) else { continue }
            let sorted = changes.sorted { ObsidianComparison.wireLine($0).sortKey < ObsidianComparison.wireLine($1).sortKey }
            var chunks: [[ObsidianPendingChange]] = []
            var chunk: [ObsidianPendingChange] = []
            var size = 0
            for change in sorted {
                try Task.checkCancellation()
                let bytes = ObsidianComparison.wireLine(change).serialized().utf8.count
                guard bytes <= ObsidianWire.maxLineBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                if !chunk.isEmpty && (chunk.count >= ObsidianWire.maxFileLines || size + bytes > ObsidianWire.maxFileBytes) {
                    chunks.append(chunk); chunk = []; size = 0
                }
                chunk.append(change); size += bytes
            }
            if !chunk.isEmpty { chunks.append(chunk) }
            for chunk in chunks {
                try Task.checkCancellation()
                let data = ObsidianWire.buildJSONL(lines: chunk.map(ObsidianComparison.wireLine))
                let itemID = ObsidianWire.itemID(vaultID: vault.id, jsonlBytes: data)
                let sha = ObsidianWire.sha256Hex(data)
                let url = directory.appendingPathComponent("\(itemID.uuidString).jsonl")
                if FileManager.default.fileExists(atPath: url.path) {
                    guard ObsidianWire.sha256Hex(try Data(contentsOf: url)) == sha else { throw CocoaError(.fileReadCorruptFile) }
                } else {
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                vault.outboxItems.append(ObsidianOutboxItem(itemID: itemID,
                    filename: ObsidianWire.fileName(for: data), window: first.changedAt.window,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(first.changedAt.window.startEpochSeconds)),
                    lineCount: chunk.count, byteCount: data.count, sha256Hex: sha,
                    timeZoneIdentifier: first.changedAt.timeZoneIdentifier, offsetSeconds: first.changedAt.offsetSeconds,
                    vaultID: vault.id, folderName: vault.folderName,
                    noteIdentityHashes: Array(Set(chunk.filter { $0.change != .removed }.map(\.logicalKey))).sorted()))
            }
            for change in changes {
                if let path = pathsByID[change.logicalKey] {
                    let previous = vault.table[path]?.lastImmutableWindowStart ?? Int64.min
                    vault.table[path]?.lastImmutableWindowStart = max(previous,
                        change.changedAt.window.startEpochSeconds)
                }
            }
            closed.insert(key)
        }
        vault.pendingChanges.removeAll { closed.contains(groupKey($0)) }
        return ObsidianPackedWindows(vault: vault, changed: !closed.isEmpty)
    }

    private static func groupKey(_ change: ObsidianPendingChange) -> String {
        "\(change.changedAt.window.startEpochSeconds)|\(change.changedAt.timeZoneIdentifier)"
    }
}
