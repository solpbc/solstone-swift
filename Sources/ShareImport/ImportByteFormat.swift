// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Consistent human-readable byte sizes and honest completion percentages for import progress UI.
nonisolated enum ImportByteFormat {
    static func bytes(_ count: Int64) -> String {
        let clamped = max(0, count)
        if clamped == 0 {
            return "0 KB"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: clamped)
    }

    /// Whole-percent completion that never claims 100% until every byte is confirmed.
    static func percent(sent: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        let clamped = min(max(0, sent), total)
        if clamped == total { return 100 }
        let raw = Int((Double(clamped) / Double(total) * 100.0).rounded())
        return min(99, max(0, raw))
    }
}
