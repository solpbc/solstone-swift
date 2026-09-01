// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The mark's chip pair at pill size.
///
/// ⚠ This drew its own bare, unfilled glyph outlines until 2026-09-01 — no tile, no
/// tint, no border — so the home pill showed two floating strokes that did not read
/// as the owner's mark at all. [`journal-mark.md`](journal-mark.md) § 2.1 is explicit
/// that a chip is *a tinted, bordered tile holding the stroked glyph*, and names the
/// 12% tint as the thing that makes it "a designed mark, not a stray icon."
///
/// ✅ It now renders `JournalMarkIconChip` — the same drawing the full card uses, at a
/// smaller side. One renderer is the point: two implementations of one mark is how
/// the pill drifted from the card in the first place.
struct JournalMarkCompactChips: View {
    let mark: JournalMark
    /// Pill scale. Every ratio in § 5 is relative to the side, so the mark holds its
    /// proportions here exactly as it does on the card.
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 22

    var body: some View {
        HStack(spacing: MarkGeometry.iconGap(side: self.side)) {
            JournalMarkIconChip(icon: self.mark.icon1, side: self.side)
            JournalMarkIconChip(icon: self.mark.icon2, side: self.side)
        }
        // A rot-45 chip's corners swing outside its own square frame; give the pair
        // room so the diamond is not clipped against its neighbour or the pill.
        .padding(.horizontal, self.side * 0.2)
        .accessibilityHidden(true)
    }
}

/// The generic mark's chip pair at pill size — same tile, dashed border, no glyph.
/// [`journal-mark.md`](journal-mark.md) § 4.3.
struct JournalMarkCompactGenericChips: View {
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 22

    var body: some View {
        HStack(spacing: MarkGeometry.iconGap(side: self.side)) {
            JournalMarkGenericChip(
                hex: JournalMarkGeneric.orangeHex,
                rotated: false,
                side: self.side
            )
            JournalMarkGenericChip(
                hex: JournalMarkGeneric.goldHex,
                rotated: true,
                side: self.side
            )
        }
        .padding(.horizontal, self.side * 0.2)
        .accessibilityHidden(true)
    }
}
