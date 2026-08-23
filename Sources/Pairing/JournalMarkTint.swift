// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owned hex→word table for journal-mark VoiceOver tokens.
/// Unverified against journal-web; this repo has no journal-mark.md.
nonisolated enum JournalMarkTint {
    static func word(hex: String) -> String {
        let normalized = Self.normalize(hex)
        return Self.table[normalized] ?? "tint"
    }

    static func chipToken(hex: String, glyphName: String) -> String {
        "\(self.word(hex: hex)) \(glyphName)"
    }

    static func spokenValue(mark: JournalMark?) -> String {
        guard let mark else {
            return SourceVocabulary.journalMarkUnavailable
        }
        let chip1 = self.chipToken(hex: mark.icon1.color.hex, glyphName: mark.icon1.name)
        let chip2 = self.chipToken(hex: mark.icon2.color.hex, glyphName: mark.icon2.name)
        let word1 = mark.words[0]
        let word2 = mark.words[1]
        return "\(chip1), \(chip2), \(word1), \(word2)"
    }

    private static func normalize(_ hex: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("#") {
            return trimmed
        }
        return "#\(trimmed)"
    }

    private static let table: [String: String] = [
        "#f59e0b": "amber",
        "#84cc16": "lime",
        "#ef4444": "red",
        "#f97316": "orange",
        "#eab308": "yellow",
        "#22c55e": "green",
        "#14b8a6": "teal",
        "#06b6d4": "cyan",
        "#3b82f6": "blue",
        "#6366f1": "indigo",
        "#8b5cf6": "violet",
        "#a855f7": "purple",
        "#ec4899": "pink",
        "#f43f5e": "rose",
        "#64748b": "slate",
        "#78716c": "stone",
    ]
}
