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
                Self.color(hex: icon.color.hex),
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
            )
            .frame(width: self.size, height: self.size)
            .rotationEffect(.degrees(icon.rot == 45 ? 45 : 0))
    }

    private static func color(hex: String) -> Color {
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

private struct CompactGlyphShape: Shape {
    let svg: String

    func path(in rect: CGRect) -> Path {
        GlyphParser.parse(innerMarkup: self.svg, in: rect) ?? Path()
    }
}
