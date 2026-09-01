// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct JournalMarkCompactChips: View {
    let mark: JournalMark
    private let size: CGFloat = 18

    var body: some View {
        HStack(spacing: 4) {
            self.chip(self.mark.icon1)
            self.chip(self.mark.icon2)
        }
        .accessibilityHidden(true)
    }

    private func chip(_ icon: JournalMark.Icon) -> some View {
        CompactGlyphShape(svg: icon.svg)
            .stroke(
                Self.markTint(hex: icon.color.hex),
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
            )
            .frame(width: self.size, height: self.size)
            .rotationEffect(.degrees(icon.rot == 45 ? 45 : 0))
    }

    static func markTint(hex: String) -> Color {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return .primary
        }
        return Color(
            red: Double((value >> 16) & 0xff) / 255.0,
            green: Double((value >> 8) & 0xff) / 255.0,
            blue: Double(value & 0xff) / 255.0
        )
    }
}

/// The generic mark at pill size: two dashed chips, no glyphs.
///
/// The shell contract makes the generic mark the org-wide no-journal-yet treatment
/// and puts it on the home pill, but the pill had been rendering no chips at all when
/// there was no mark to draw — so the one place identity lives went blank exactly
/// when an owner most needs to see that a journal is missing. Same two colours and
/// the same dashed outline as the full card, sized for the pill.
struct JournalMarkCompactGenericChips: View {
    private let size: CGFloat = 18

    var body: some View {
        HStack(spacing: 4) {
            self.chip(hex: JournalMarkGeneric.orangeHex, rotated: false)
            self.chip(hex: JournalMarkGeneric.goldHex, rotated: true)
        }
        .accessibilityHidden(true)
    }

    private func chip(hex: String, rotated: Bool) -> some View {
        let color = JournalMarkCompactChips.markTint(hex: hex)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: 1.25,
                    dash: [
                        JournalMarkGeneric.dashOn(side: self.size),
                        JournalMarkGeneric.dashOff(side: self.size),
                    ]
                )
            )
            .frame(width: self.size, height: self.size)
            .rotationEffect(.degrees(rotated ? 45 : 0))
    }
}

private struct CompactGlyphShape: Shape {
    let svg: String

    func path(in rect: CGRect) -> Path {
        GlyphParser.parse(innerMarkup: self.svg, in: rect) ?? Path()
    }
}
