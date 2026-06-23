// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum DiagnosticsEventFilter {
    static func matches(_ event: DiagnosticEvent, categories: Set<DiagnosticCategory>, problemsOnly: Bool) -> Bool {
        guard categories.contains(event.category) else { return false }
        if problemsOnly && event.severity.rowEmphasis == .normal { return false }
        return true
    }
}

struct FailedSegmentPresentation: Equatable {
    var headline: String
    var subtext: String
    var showsButton: Bool
}

enum FailedSegmentSection {
    static func presentation(failedTotal: Int, isConnected: Bool) -> FailedSegmentPresentation? {
        guard failedTotal > 0 else { return nil }
        let headline = failedTotal > 1
            ? "\(failedTotal) segments haven't reached your journal"
            : "1 segment hasn't reached your journal"
        if isConnected {
            return FailedSegmentPresentation(
                headline: headline,
                subtext: "they'll try again automatically the next time you reconnect.",
                showsButton: true
            )
        } else {
            return FailedSegmentPresentation(
                headline: headline,
                subtext: "you're offline — these will try again automatically when you reconnect.",
                showsButton: false
            )
        }
    }
}
