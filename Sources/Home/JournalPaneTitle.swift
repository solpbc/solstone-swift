// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func journalPaneTitle(mark: JournalMark?) -> String {
    if let mark {
        return mark.words.joined(separator: " · ")
    }
    return JournalMarkGeneric.words.joined(separator: " · ")
}
