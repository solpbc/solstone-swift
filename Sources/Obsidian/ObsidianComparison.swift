// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Pure planning. The caller commits this value before replaying any external
/// intake operation. Disk aliases and represented paths deliberately differ
/// while a moved note is unavailable or too large to keep.
nonisolated enum ObsidianComparison {
    static func reduce(_ original: ObsidianVaultState, snapshot: ObsidianWalkSnapshot,
                       observed: ObsidianStamp) throws -> ObsidianVaultState {
        var vault = original
        let baseline = !vault.baselineCompleted
        var current: [String: ObsidianWalkedNote] = [:]
        for note in snapshot.notes {
            guard current.updateValue(note, forKey: note.relativePath) == nil else { throw ObsidianWalkError.enumerationFailed }
        }
        var missing = Set(vault.table.keys.filter { current[$0] == nil })
        var appeared = Set(current.keys.filter {
            vault.table[$0] == nil || (vault.table[$0]?.representedPath == nil && vault.table[$0]?.contentIsCurrent == false)
        })
        var pairs: [String: String] = [:]
        // Stable identity first, then equal normalized content, in byte order.
        for old in missing.sorted(by: byteOrder) {
            guard let id = vault.table[old]?.documentIdentifier,
                  let new = appeared.sorted(by: byteOrder).first(where: { current[$0]?.documentIdentifier == id }) else { continue }
            pairs[new] = old; missing.remove(old); appeared.remove(new)
        }
        for old in missing.sorted(by: byteOrder) {
            guard let hash = vault.table[old]?.contentHash, !hash.isEmpty,
                  let new = appeared.sorted(by: byteOrder).first(where: {
                      if case .sendable(_, let candidateHash) = current[$0]?.content { return candidateHash == hash }
                      return false
                  }) else { continue }
            pairs[new] = old; missing.remove(old); appeared.remove(new)
        }
        var anchor: Int64?
        for note in snapshot.notes {
            guard let old = original.table[note.relativePath],
                  case .sendable(_, let hash) = note.content, hash != old.contentHash else { continue }
            let sec = seconds(note.mtimeMs)
            if sec > (original.lastChecked.map { Int64($0.timeIntervalSince1970) } ?? Int64.min), sec <= observed.epochSeconds {
                anchor = min(anchor ?? sec, sec)
            }
        }
        vault.unavailableCount = snapshot.unavailableCount
        vault.tooLargeCount = snapshot.tooLargeCount
        if baseline {
            let hashes = current.keys.sorted(by: byteOrder).map { ObsidianWire.noteIdentity(vaultID: vault.id, path: $0) }
            vault.frozenBaselineHashes = hashes
            appendOp(&vault, kind: .seed, hash: "", time: observed.date, baseline: hashes)
            vault.baselineCompleted = true // includes an empty first listing
        }

        for path in current.keys.sorted(by: byteOrder) {
            try Task.checkCancellation()
            guard let note = current[path] else { continue }
            let oldPath = pairs[path] ?? path
            let old = vault.table[oldPath]
            var record = old ?? ObsidianNoteRecord(path: path, documentIdentifier: note.documentIdentifier,
                mtimeMs: note.mtimeMs, sizeBytes: note.size, contentHash: "", text: "",
                lastReportedTime: nil, lastReportedWindowKey: nil, firstObservedMissingAt: nil,
                intakeKept: baseline, contentIsCurrent: false)
            record.path = path
            record.documentIdentifier = note.documentIdentifier ?? record.documentIdentifier
            record.firstMissingStamp = nil
            record.firstObservedMissingAt = nil
            if oldPath != path {
                vault.table.removeValue(forKey: oldPath)
                if record.intakeKept {
                    appendOp(&vault, kind: .move, hash: identity(vault, path), time: observed.date,
                             previous: identity(vault, oldPath))
                }
            }
            guard case .sendable(let text, let hash) = note.content else {
                record.contentIsCurrent = false
                vault.table[path] = record
                continue
            }
            let moved = record.representedPath != nil && record.representedPath != path
            let changed = record.representedPath == nil || hash != record.contentHash
            if changed || moved {
                let candidate: ObsidianStamp
                if moved && !changed {
                    candidate = anchor.map { ObsidianStamp(epochSeconds: $0, timeZone: zone(observed)) } ?? observed
                } else {
                    let sec = seconds(note.mtimeMs)
                    candidate = sec > observed.epochSeconds || sec <= (record.lastReportedTime ?? Int64.min)
                        ? observed : ObsidianStamp(epochSeconds: sec, timeZone: zone(observed))
                }
                let stamp = mutableStamp(candidate, record: record, observed: observed)
                var change = ObsidianPendingChange(change: moved ? .renamed : .changed,
                    vault: vault.folderName, path: path, previousPath: moved ? record.representedPath : nil,
                    changedAt: stamp, observedAt: observed, text: text, contentHash: hash,
                    logicalKey: record.logicalID, windowKey: stamp.window.key,
                    documentIdentifier: note.documentIdentifier, firstSight: record.representedPath == nil)
                if let existing = vault.pendingChanges.first(where: { sameWindow($0, change) }) {
                    change = merged(existing, change)
                }
                let line = wireLine(change)
                guard line.serialized().utf8.count <= ObsidianWire.maxLineBytes else {
                    vault.tooLargeCount += 1
                    record.contentIsCurrent = false
                    vault.table[path] = record
                    continue
                }
                coalesce(&vault.pendingChanges, change)
                record.representedPath = path
                record.lastReportedTime = stamp.epochSeconds
                record.lastReportedWindowKey = stamp.window.key
                if !record.intakeKept {
                    appendOp(&vault, kind: .keep, hash: identity(vault, path), time: observed.date)
                    record.intakeKept = true
                }
            }
            record.contentHash = hash; record.text = text
            record.mtimeMs = note.mtimeMs; record.sizeBytes = note.size
            record.contentIsCurrent = true
            vault.table[path] = record
        }
        // An unidentified unreadable candidate may be a moved missing note.
        // Hold disappearance confirmation until a complete interpretable listing.
        let missingWithoutIdentity = missing.contains { vault.table[$0]?.documentIdentifier == nil }
        let unknownCandidate = current.keys.contains { path in
            guard let note = current[path], note.documentIdentifier == nil || missingWithoutIdentity else { return false }
            switch note.content { case .unavailable, .readFailed, .tooLarge: return true; default: return false }
        }
        if !unknownCandidate {
            for path in missing.sorted(by: byteOrder) {
                try Task.checkCancellation()
                guard var record = vault.table[path] else { continue }
                guard let first = record.firstMissingStamp else {
                    record.firstMissingStamp = observed
                    record.firstObservedMissingAt = observed.epochSeconds
                    vault.table[path] = record
                    continue
                }
                if let represented = record.representedPath {
                    if record.lastImmutableWindowStart == nil {
                        vault.pendingChanges.removeAll { $0.logicalKey == record.logicalID }
                    } else {
                        let stamp = mutableStamp(first, record: record, observed: observed)
                        let change = ObsidianPendingChange(change: .removed, vault: vault.folderName,
                            path: represented, previousPath: nil, changedAt: stamp, observedAt: first,
                            text: nil, contentHash: nil, logicalKey: record.logicalID,
                            windowKey: stamp.window.key, documentIdentifier: record.documentIdentifier)
                        coalesce(&vault.pendingChanges, change)
                    }
                }
                if record.intakeKept { appendOp(&vault, kind: .remove, hash: identity(vault, path), time: observed.date) }
                vault.table.removeValue(forKey: path)
            }
        }
        vault.foundNoteIdentities = Set(vault.table.values.filter { $0.representedPath != nil }.map(\.logicalID))
        vault.foundNotesCount = vault.foundNoteIdentities.count
        vault.lastChecked = observed.date
        return vault
    }

    static func wireLine(_ c: ObsidianPendingChange) -> ObsidianNoteLine {
        ObsidianNoteLine(change: c.change, vault: c.vault, path: c.path, previousPath: c.previousPath,
            changedAt: c.changedAt, observedAt: c.observedAt, text: c.text, contentHash: c.contentHash)
    }
    private static func identity(_ v: ObsidianVaultState, _ path: String) -> String { ObsidianWire.noteIdentity(vaultID: v.id, path: path) }
    private static func byteOrder(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    private static func seconds(_ ms: Int64) -> Int64 { ms >= 0 ? ms / 1000 : (ms - 999) / 1000 }
    private static func zone(_ stamp: ObsidianStamp) -> TimeZone { TimeZone(identifier: stamp.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: Int(stamp.offsetSeconds))! }
    private static func mutableStamp(_ candidate: ObsidianStamp, record: ObsidianNoteRecord, observed: ObsidianStamp) -> ObsidianStamp {
        if let immutable = record.lastImmutableWindowStart, candidate.window.startEpochSeconds <= immutable { return observed }
        return candidate
    }
    private static func sameWindow(_ a: ObsidianPendingChange, _ b: ObsidianPendingChange) -> Bool {
        a.logicalKey == b.logicalKey && a.changedAt.window.startEpochSeconds == b.changedAt.window.startEpochSeconds
    }
    private static func merged(_ old: ObsidianPendingChange, _ new: ObsidianPendingChange) -> ObsidianPendingChange {
        var value = new
        value.firstSight = old.firstSight
        if new.change == .removed {
            value.path = old.previousPath ?? old.path
            value.previousPath = nil
        } else if old.firstSight {
            value.change = .changed; value.previousPath = nil
        } else if old.change == .renamed {
            value.change = .renamed; value.previousPath = old.previousPath
        }
        return value
    }
    private static func coalesce(_ pending: inout [ObsidianPendingChange], _ change: ObsidianPendingChange) {
        if let index = pending.firstIndex(where: { sameWindow($0, change) }) {
            let old = pending[index]
            if old.firstSight && change.change == .removed { pending.remove(at: index) }
            else { pending[index] = merged(old, change) }
        } else { pending.append(change) }
    }
    private static func appendOp(_ vault: inout ObsidianVaultState, kind: ObsidianUnappliedIntakeOp.Kind,
                                 hash: String, time: Date, previous: String? = nil, baseline: [String] = []) {
        vault.intakeSequence += 1
        vault.unappliedIntakeOps.append(ObsidianUnappliedIntakeOp(hash: hash, intakeTime: time,
            sequence: vault.intakeSequence, kind: kind, previousHash: previous, baselineHashes: baseline))
    }
}
