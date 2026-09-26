// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceDetailPresentation {
    static var modeExplanation: String { SourceVocabulary.modeExplanation }

    /// The running timer. The state card's verdict line already says "on", so this is the time alone.
    static func elapsedLine(formatted: String) -> String {
        formatted
    }

    static func elapsedAccessibilityLabel(formatted: String) -> String {
        "\(SourceVocabulary.observerActiveSubtext) for \(formatted)"
    }
}

nonisolated struct AudioDeliverySummary: Equatable, Sendable {
    let line: String
}

/// The audio pane's delivery line, in audio's own words.
nonisolated enum AudioDetailPresentation {
    static func deliverySummary(pending: Int, failed: Int) -> AudioDeliverySummary {
        if failed > 0 {
            let phrase = failed == 1 ? "recording needs attention." : "recordings need attention."
            return AudioDeliverySummary(line: "\(failed) \(phrase)")
        }

        if pending > 0 {
            let phrase = pending == 1 ? "recording on the way to your journal." : "recordings on the way to your journal."
            return AudioDeliverySummary(line: "\(pending) \(phrase)")
        }

        return AudioDeliverySummary(line: "nothing waiting right now.")
    }
}
