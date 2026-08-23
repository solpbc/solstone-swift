// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated let journalPaneNilTitle = "dev-copy: this page"

nonisolated func journalPaneTitle(mark: JournalMark?, pageTitle: String) -> String {
    if let mark {
        return mark.words.joined(separator: " · ")
    }
    let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }
    return journalPaneNilTitle
}
