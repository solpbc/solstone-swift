// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum DiagnosticsEventFilter {
    static func matches(_ event: DiagnosticEvent, categories: Set<DiagnosticCategory>, problemsOnly: Bool) -> Bool {
        guard categories.contains(event.category) else { return false }
        if problemsOnly && event.severity.rowEmphasis == .normal { return false }
        return true
    }
}
