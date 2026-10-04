// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Visual and spoken contract for the generic mark (nil / absent / malformed / not-committed).
/// Dash units and palette hexes live here, not in `MarkGeometry`.
nonisolated enum JournalMarkGeneric {
    static let words = ["your", "journal"]
    static let spokenValue = "your journal, not set up yet"
    static let orangeHex = "#E8913A"
    static let goldHex = "#D4A017"
    static let fillOpacity = 0.07
    static let dashOnUnits: CGFloat = 3.2
    static let dashOffUnits: CGFloat = 2.4
    static let dashReferenceSide: CGFloat = 27

    static func dashOn(side: CGFloat) -> CGFloat {
        Self.dashOnUnits * side / Self.dashReferenceSide
    }

    static func dashOff(side: CGFloat) -> CGFloat {
        Self.dashOffUnits * side / Self.dashReferenceSide
    }
}

nonisolated enum JournalMarkAccessibility {
    static func spokenValue(mark: JournalMark) -> String {
        let name1 = mark.icon1.color.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name2 = mark.icon2.color.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let word1 = mark.words.first ?? ""
        let word2 = mark.words.count > 1 ? mark.words[1] : ""

        if !name1.isEmpty && !name2.isEmpty {
            return "\(name1), \(name2), \(word1), \(word2)"
        }
        return "\(word1), \(word2)"
    }
}

