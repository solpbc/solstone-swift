// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Text rules for values the diagnostics export prints from an item's own fields.
///
/// A stored day or segment can hold anything a formatter once wrote: a narrow no-break space,
/// non-ASCII digits, a combining mark. Printing it raw would make two different values look
/// alike in the file, so every such value is rendered with only printable ASCII inside its
/// delimiters, and the exact scalars stay recoverable.
nonisolated enum DiagnosticExportText {
    static let openDelimiter = "«"
    static let closeDelimiter = "»"

    /// Iterates `unicodeScalars`: `\` renders as `\\`; any scalar outside U+0020...U+007E renders
    /// as `\u{XXXX}`, uppercase hex, at least four digits; everything else is kept as is.
    static func escaped(_ value: String) -> String {
        var rendered = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C:
                rendered += #"\\"#
            case 0x20...0x7E:
                rendered.unicodeScalars.append(scalar)
            default:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                let padding = String(repeating: "0", count: max(0, 4 - hex.count))
                rendered += #"\u{"# + padding + hex + "}"
            }
        }
        return rendered
    }

    /// `escaped(value)` between `«` and `»`. An empty value renders as `«»`.
    static func delimited(_ value: String) -> String {
        Self.openDelimiter + Self.escaped(value) + Self.closeDelimiter
    }
}

/// One refused item, reduced to the fields the diagnostics export may print.
///
/// Built by allowlist: the refusal time, the short app version, the observer-ingest `day` and
/// `segment`, and the journal's reason code. Nothing else from the manifest reaches the export.
nonisolated struct RefusedItemExportRecord: Equatable, Sendable {
    /// Where the reason code was read from.
    enum CodeOrigin: Equatable, Sendable {
        /// The attention record's own `journalReasonCode`.
        case recorded
        /// A record stored before that field existed, whose detail was `reason_code=<code>`.
        case storedDetail
    }

    /// The item's current observer-ingest key.
    struct IngestKey: Equatable, Sendable {
        let day: String
        let segment: String
    }

    static let storedDetailPrefix = "reason_code="

    let itemID: UUID
    let refusedAt: Date
    let appVersion: String?
    /// `nil` for an item without observer-ingest metadata (a share, for example).
    let ingestKey: IngestKey?
    let reasonCode: String
    let codeOrigin: CodeOrigin

    /// `nil` unless the manifest is a journal refusal: an attention record carrying the journal's
    /// reason code, or an older refusal record whose stored detail names it.
    init?(manifest: TransferManifest) {
        guard let attention = manifest.attention,
              let (code, origin) = Self.reasonCode(of: attention)
        else { return nil }
        self.itemID = manifest.itemID
        self.refusedAt = attention.movedAt
        self.appVersion = manifest.appVersion
        self.ingestKey = manifest.observerIngest.map { IngestKey(day: $0.day, segment: $0.segment) }
        self.reasonCode = code
        self.codeOrigin = origin
    }

    private static func reasonCode(of attention: TransferAttentionInfo) -> (String, CodeOrigin)? {
        if let code = attention.journalReasonCode, !code.isEmpty {
            return (code, .recorded)
        }
        guard attention.reason == TransferAttentionReason.httpClientErrorCode,
              attention.shortDetail.hasPrefix(Self.storedDetailPrefix)
        else { return nil }
        let code = String(attention.shortDetail.dropFirst(Self.storedDetailPrefix.count))
        guard !code.isEmpty else { return nil }
        return (code, .storedDetail)
    }

    /// The reason code as printed, with its origin when it was read from a stored detail.
    var reasonLabel: String {
        let code = DiagnosticExportText.escaped(self.reasonCode)
        switch self.codeOrigin {
        case .recorded:
            return code
        case .storedDetail:
            return "\(code) (from stored detail)"
        }
    }
}

/// The refused-items part of one source's "sync state by source" block in the diagnostics
/// export. Only journal refusals are counted here; other attention items keep their own lines.
nonisolated struct RefusedItemsExport: Equatable, Sendable {
    static let listedLimit = 5
    static let appVersionNote =
        "refused items: app version is the short version only and cannot tell builds of one version apart"

    /// Every refusal on the source, most recently refused first.
    let refusals: [RefusedItemExportRecord]

    init(manifests: [TransferManifest]) {
        self.refusals = manifests
            .compactMap(RefusedItemExportRecord.init(manifest:))
            .sorted { lhs, rhs in
                if lhs.refusedAt != rhs.refusedAt { return lhs.refusedAt > rhs.refusedAt }
                return lhs.itemID.uuidString < rhs.itemID.uuidString
            }
    }

    /// The refusals the export lists, newest first.
    var listed: ArraySlice<RefusedItemExportRecord> {
        self.refusals.prefix(Self.listedLimit)
    }

    /// Count per printed reason label, largest first, then by label.
    var countsByReason: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for refusal in self.refusals {
            counts[refusal.reasonLabel, default: 0] += 1
        }
        return counts
            .map { (label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.label < rhs.label
            }
    }

    func lines(sourceName: String, now: Date) -> [String] {
        guard !self.refusals.isEmpty else {
            return [
                "  \(sourceName) refused by reason: none",
                "  \(sourceName) refused items: none",
            ]
        }
        var lines = ["  \(sourceName) refused by reason:"]
        lines += self.countsByReason.map { "    \($0.label): \($0.count)" }
        let total = self.refusals.count
        lines.append(
            "  \(sourceName) refused items (\(self.listed.count) most recently refused of \(total) "
                + (total == 1 ? "refusal):" : "refusals):")
        )
        lines += self.listed.map { "    " + Self.itemFields($0, now: now).joined(separator: ", ") }
        return lines
    }

    /// The fields of one listed item, in order. Values taken from the item are escaped.
    static func itemFields(_ refusal: RefusedItemExportRecord, now: Date) -> [String] {
        var fields = [
            "refused \(age(from: refusal.refusedAt, to: now)) ago",
            "app " + (refusal.appVersion.flatMap { $0.isEmpty ? nil : DiagnosticExportText.escaped($0) } ?? "not recorded"),
        ]
        if let key = refusal.ingestKey {
            fields.append("day " + DiagnosticExportText.delimited(key.day))
            fields.append("segment " + DiagnosticExportText.delimited(key.segment))
        } else {
            fields.append("no ingest metadata")
        }
        fields.append("reason " + refusal.reasonLabel)
        return fields
    }
}
