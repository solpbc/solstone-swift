// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct DayHomeAskBar: View {
    let title: String
    let isEnabled: Bool
    let foldBadgeVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 10) {
                Image("SolRing")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                Text(self.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dayHome.askBar.hint")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if self.foldBadgeVisible {
                    Circle()
                        .fill(Color.solOrangeAccessible)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .accessibilityIdentifier("dayHome.askBar")
        .accessibilityValue(self.foldBadgeVisible ? "attention" : "clear")
    }
}
