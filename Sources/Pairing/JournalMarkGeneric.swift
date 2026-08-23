// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Visual and spoken contract for the generic mark (nil / absent / malformed / not-committed).
/// Dash units and palette hexes live here, not in `MarkGeometry`.
nonisolated enum JournalMarkGeneric {
    static let words = ["your", "journal"]
    static let spokenValue = "your journal, not set up yet"
    static let orangeHex = "#E8923A"
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
    static func chipToken(colorName: String?, glyphName: String) -> String {
        let tint = colorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tint.isEmpty {
            return glyphName
        }
        return "\(tint) \(glyphName)"
    }

    static func spokenValue(mark: JournalMark?) -> String {
        guard let mark, mark.words.count >= 2 else {
            return JournalMarkGeneric.spokenValue
        }
        let chip1 = Self.chipToken(colorName: mark.icon1.color.name, glyphName: mark.icon1.name)
        let chip2 = Self.chipToken(colorName: mark.icon2.color.name, glyphName: mark.icon2.name)
        return "\(chip1), \(chip2), \(mark.words[0]), \(mark.words[1])"
    }
}
