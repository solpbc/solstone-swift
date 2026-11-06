// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Visual and spoken contract for the generic mark (nil / absent / malformed / not-committed).
/// Dash units and palette hexes live here, not in `MarkGeometry`.
nonisolated enum JournalMarkGeneric {
    static let words = ["your", "journal"]
    static let spokenValue = "your journal, not set up yet"
    static let awaitingConfirmationSpokenValue = "your journal, mark not confirmed yet"
    /// The dashes are drawn on paper, so they need to clear 3:1 against paper, not against
    /// whatever ground the mark sits on (journal-mark.md section 4.3, amended 2026-11-06).
    static let orangeHex = "#B06A1A"
    static let goldHex = "#A57F0E"
    /// The chip's own ground. It fills the chip and also runs under the dashed border, so every
    /// dash and gap sits on paper: over glass or the night ground the old tinted chip read 1.0:1.
    static let paperHex = "#FEFCF8"
    /// The paper backing under the border, as a multiple of the border width.
    static let backingWidthRatio: CGFloat = 3
    /// A peer that presented no identity is not ours, so its slot takes no brand colour.
    static let neutralHex = "#6E6453"
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

