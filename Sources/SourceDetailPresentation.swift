// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceDetailPresentation {
    static var modeExplanation: String { SourceVocabulary.modeExplanation }
    static var listeningIndicatorWord: String { SourceVocabulary.observerActiveSubtext }

    static func elapsedLine(formatted: String) -> String {
        "\(SourceVocabulary.observerActiveSubtext) · \(formatted)"
    }
}
