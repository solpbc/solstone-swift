// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation

/// The Obsidian note wire contract, v1.
nonisolated enum ObsidianWire {
    static let source = "obsidian"
    static let capability = "obsidian_notes"
    static let filePrefix = "obsidian_"
    static let fileSuffix = ".jsonl"
    static let maxFileLines = 5_000
    static let maxFileBytes = 8 * 1024 * 1024
    static let maxLineBytes = 8 * 1024 * 1024
    static let maxNoteBytes = 4 * 1024 * 1024
    static let windowSeconds: Int64 = 300
    static let windowCloseSeconds: Int64 = 90
    static let maxVaultNameBytes = 128
    static let maxNoteFileSizeBytes = maxNoteBytes
    static let maxLineSizeBytes = maxLineBytes

    static func isNoteSizeSendable(_ bytes: Int64) -> Bool {
        bytes <= Int64(maxNoteBytes)
    }

    static func isNoteSizeSendable(_ bytes: Int) -> Bool {
        bytes <= maxNoteBytes
    }

    static func noteIdentity(vaultID: String, path: String) -> String {
        let combined = vaultID + path
        return SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func filename(forBytes bytes: Data) -> String {
        fileName(for: bytes)
    }

    static func sortLines(_ lines: [ObsidianNoteLine]) -> [ObsidianNoteLine] {
        lines.sorted { $0.sortKey < $1.sortKey }
    }

    static func buildJSONL(lines: [ObsidianNoteLine]) -> Data {
        Data(lines.map { $0.serialized() }.joined().utf8)
    }

    static func splitLines(_ lines: [ObsidianNoteLine]) -> [[ObsidianNoteLine]] {
        var chunks: [[ObsidianNoteLine]] = []
        var currentChunk: [ObsidianNoteLine] = []
        var currentBytes = 0
        for line in lines {
            let lineBytes = line.serialized().utf8.count
            if !currentChunk.isEmpty && (currentChunk.count >= maxFileLines || currentBytes + lineBytes > maxFileBytes) {
                chunks.append(currentChunk)
                currentChunk = []
                currentBytes = 0
            }
            currentChunk.append(line)
            currentBytes += lineBytes
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks
    }

    static func sha256Hex(_ data: some DataProtocol) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(for bytes: Data) -> String {
        "\(filePrefix)\(sha256Hex(bytes))\(fileSuffix)"
    }

    /// Derives a stable item ID (UUID) from the first 16 bytes of SHA-256(vaultID.utf8 + [0x00] + jsonlBytes).
    static func itemID(vaultID: String, jsonlBytes: Data) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(vaultID.utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: jsonlBytes)
        let digest = hasher.finalize()
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Whether a vault's folder name can travel as the `vault` field.
    /// Limits: 1–128 UTF-8 bytes, not whitespace-only, not .obsidian, no slash/colon, and no control scalars.
    static func isUsableVaultName(_ name: String) -> Bool {
        let count = name.utf8.count
        guard count >= 1 && count <= maxVaultNameBytes else { return false }
        return !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Whether a note path can travel.
    /// Path nonempty, slash-separated, relative, no backslash, no controls,
    /// no empty / "." / ".." / dot-prefixed segment, no templates or _templates segment in any case,
    /// .md suffix in any case.
    static func isSendablePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard !path.hasPrefix("/") else { return false }
        guard !path.contains("\\") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        guard path.lowercased().hasSuffix(".md") else { return false }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            guard !segment.isEmpty else { return false }
            if segment == "." || segment == ".." { return false }
            if segment.hasPrefix(".") { return false }
            let lower = segment.lowercased()
            if lower == "templates" || lower == "_templates" { return false }
        }
        return true
    }

    /// Validates previous_path: either null (nil) or satisfies isSendablePath.
    static func isSendablePreviousPath(_ path: String?) -> Bool {
        guard let path else { return true }
        return isSendablePath(path)
    }

    /// Cadence while active: 60 seconds, or 100× completed scan duration capped at 15 minutes when > 600 ms.
    static func scanInterval(afterScanTaking duration: TimeInterval) -> TimeInterval {
        guard duration > 0.6 else { return 60 }
        return min(duration * 100, 15 * 60)
    }
}

/// A moment, retaining the original IANA timezone identifier and offset.
nonisolated struct ObsidianStamp: Codable, Equatable, Sendable {
    let epochSeconds: Int64
    let offsetSeconds: Int32
    let timeZoneIdentifier: String

    init(epochSeconds: Int64, timeZone: TimeZone) {
        self.epochSeconds = epochSeconds
        self.timeZoneIdentifier = timeZone.identifier
        let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
        // An offset carrying non-zero seconds cannot be written in RFC 3339 numeric offset, so it is written as UTC (Z).
        self.offsetSeconds = (offset % 60 == 0) ? Int32(offset) : 0
    }

    init(epochSeconds: Int64, offsetSeconds: Int32, timeZoneIdentifier: String) {
        self.epochSeconds = epochSeconds
        self.offsetSeconds = (offsetSeconds % 60 == 0) ? offsetSeconds : 0
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    init(milliseconds: Int64, timeZone: TimeZone) {
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        self.init(epochSeconds: seconds, timeZone: timeZone)
    }

    init(date: Date, timeZone: TimeZone) {
        self.init(epochSeconds: Int64(date.timeIntervalSince1970), timeZone: timeZone)
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    private struct Wall {
        let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    }

    private var wall: Wall {
        var seconds = time_t(epochSeconds + Int64(offsetSeconds))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return Wall(
            year: Int(parts.tm_year) + 1900,
            month: Int(parts.tm_mon) + 1,
            day: Int(parts.tm_mday),
            hour: Int(parts.tm_hour),
            minute: Int(parts.tm_min),
            second: Int(parts.tm_sec)
        )
    }

    var isRepresentable: Bool { (1...9999).contains(wall.year) }

    /// RFC3339 whole seconds, numeric offset or Z. Offset 0 is Z. An offset whose seconds component is non-zero is Z.
    var rfc3339: String {
        let w = wall
        let date = "\(pad(w.year, 4))-\(pad(w.month, 2))-\(pad(w.day, 2))"
        let time = "\(pad(w.hour, 2)):\(pad(w.minute, 2)):\(pad(w.second, 2))"
        guard offsetSeconds != 0 else { return "\(date)T\(time)Z" }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(Int(offsetSeconds))
        return "\(date)T\(time)\(sign)\(pad(magnitude / 3600, 2)):\(pad((magnitude % 3600) / 60, 2))"
    }

    var rfc3339String: String { rfc3339 }

    var closeEpochSeconds: Int64 {
        window.startEpochSeconds + ObsidianWire.windowSeconds + ObsidianWire.windowCloseSeconds
    }

    /// The 300-second window this moment's wall clock, in its own offset, falls inside.
    var window: ObsidianWindow {
        let w = wall
        let seconds = w.hour * 3600 + w.minute * 60 + w.second
        let floored = seconds - (seconds % Int(ObsidianWire.windowSeconds))
        let remainder = Int64(seconds % Int(ObsidianWire.windowSeconds))
        let startEpoch = epochSeconds - remainder
        return ObsidianWindow(
            day: "\(pad(w.year, 4))\(pad(w.month, 2))\(pad(w.day, 2))",
            segment: "\(pad(floored / 3600, 2))\(pad((floored % 3600) / 60, 2))00_\(ObsidianWire.windowSeconds)",
            startEpochSeconds: startEpoch,
            durationSeconds: ObsidianWire.windowSeconds
        )
    }

    private func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

/// One five-minute window, named as it travels.
nonisolated struct ObsidianWindow: Hashable, Codable, Sendable, Comparable {
    let day: String
    let segment: String
    var startEpochSeconds: Int64
    var durationSeconds: Int64

    var key: String { "\(day)-\(segment)" }

    init(day: String, segment: String, startEpochSeconds: Int64 = 0, durationSeconds: Int64 = ObsidianWire.windowSeconds) {
        self.day = day
        self.segment = segment
        self.startEpochSeconds = startEpochSeconds
        self.durationSeconds = durationSeconds
    }

    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 10 else { return nil }
        self.init(day: String(parts[0]), segment: String(parts[1]))
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }

    /// The UTC start time of the window, computed directly from the stored offsetSeconds.
    func startDate(offsetSeconds: Int32) -> Date? {
        guard let year = Int(day.prefix(4)),
              let month = Int(day.dropFirst(4).prefix(2)),
              let dayOfMonth = Int(day.suffix(2)),
              let hour = Int(segment.prefix(2)),
              let minute = Int(segment.dropFirst(2).prefix(2))
        else { return nil }

        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(dayOfMonth)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        parts.tm_sec = 0
        let wallEpoch = Int64(timegm(&parts))
        let utcEpoch = wallEpoch - Int64(offsetSeconds)
        return Date(timeIntervalSince1970: TimeInterval(utcEpoch))
    }

    /// When this window closes: 90 seconds after its 300s end, computed from the stored offsetSeconds.
    func closeDate(offsetSeconds: Int32) -> Date? {
        guard let start = startDate(offsetSeconds: offsetSeconds) else { return nil }
        return start.addingTimeInterval(TimeInterval(ObsidianWire.windowSeconds + ObsidianWire.windowCloseSeconds))
    }
}

nonisolated enum ObsidianChange: String, Codable, Equatable, Sendable {
    case changed
    case renamed
    case removed
}

nonisolated struct ObsidianLineSortKey: Comparable, Sendable {
    let vault: String
    let path: String
    let changedAt: String
    let change: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.vault.utf8.elementsEqual(rhs.vault.utf8) {
            if lhs.path.utf8.elementsEqual(rhs.path.utf8) {
                if lhs.changedAt.utf8.elementsEqual(rhs.changedAt.utf8) {
                    return lhs.change.utf8.lexicographicallyPrecedes(rhs.change.utf8)
                }
                return lhs.changedAt.utf8.lexicographicallyPrecedes(rhs.changedAt.utf8)
            }
            return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
        return lhs.vault.utf8.lexicographicallyPrecedes(rhs.vault.utf8)
    }
}

/// One line of a note file.
nonisolated struct ObsidianNoteLine: Equatable, Sendable {
    var change: ObsidianChange
    var vault: String
    var path: String
    var previousPath: String?
    var changedAt: ObsidianStamp
    var observedAt: ObsidianStamp
    var text: String?
    var contentHash: String?

    init(
        change: ObsidianChange,
        vault: String,
        path: String,
        previousPath: String? = nil,
        changedAt: ObsidianStamp,
        observedAt: ObsidianStamp,
        text: String? = nil,
        contentHash: String? = nil
    ) {
        self.change = change
        self.vault = vault
        self.path = path
        self.previousPath = previousPath
        self.changedAt = changedAt
        self.observedAt = observedAt
        self.text = text
        self.contentHash = contentHash
    }

    init(
        vault: String,
        path: String,
        change: ObsidianChange,
        changedAt: ObsidianStamp,
        observedAt: ObsidianStamp,
        previousPath: String? = nil,
        text: String? = nil,
        contentHash: String? = nil
    ) {
        self.change = change
        self.vault = vault
        self.path = path
        self.previousPath = previousPath
        self.changedAt = changedAt
        self.observedAt = observedAt
        self.text = text
        self.contentHash = contentHash
    }

    var sortKey: ObsidianLineSortKey {
        ObsidianLineSortKey(
            vault: vault,
            path: path,
            changedAt: changedAt.rfc3339,
            change: change.rawValue
        )
    }

    func formatLine() -> String {
        serialized()
    }

    func encodedBytes() -> Data {
        Data(serialized().utf8)
    }

    /// Serializes one line to compact JSON bytes using CalendarJSON, with sorted keys and a trailing newline.
    func serialized() -> String {
        let fields: [String: CalendarJSON] = [
            "v": .int(1),
            "change": .string(change.rawValue),
            "vault": .string(vault),
            "path": .string(path),
            "previous_path": CalendarJSON.optional(previousPath),
            "changed_at": .string(changedAt.rfc3339),
            "observed_at": .string(observedAt.rfc3339),
            "text": CalendarJSON.optional(text),
            "content_hash": CalendarJSON.optional(contentHash)
        ]
        return CalendarJSON.object(fields).serialized + "\n"
    }
}
