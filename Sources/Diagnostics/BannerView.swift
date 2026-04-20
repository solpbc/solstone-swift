// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct BannerView: View {
    let item: BannerPresenter.BannerItem
    let onTap: () -> Void
    let onDismiss: () -> Void

    private var accentColor: Color {
        switch self.item.event.category {
        case .tunnel, .network:
            .orange
        case .voice:
            .blue
        case .upload:
            .green
        case .brain:
            .purple
        }
    }

    private var severityIcon: String {
        switch self.item.event.severity {
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle"
        case .error:
            "xmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(self.accentColor)
                .frame(width: 3)

            Image(systemName: self.severityIcon)
                .font(.subheadline)
                .foregroundStyle(self.accentColor)

            Text(self.item.event.message)
                .font(.subheadline)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 320)
        .padding(.horizontal, 8)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: self.onTap)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height > 20 {
                        self.onDismiss()
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("tap to view diagnostics, swipe down to dismiss")
    }
}
