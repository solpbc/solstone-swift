// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourceDetailBlock<Content: View>: View {
    let title: String
    let titleIdentifier: String?
    private let content: Content

    init(
        title: String,
        titleIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleIdentifier = titleIdentifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let titleIdentifier = self.titleIdentifier {
                Text(self.title)
                    .font(ShellFont.sectionTitle)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(titleIdentifier)
            } else {
                Text(self.title)
                    .font(ShellFont.sectionTitle)
                    .foregroundStyle(.primary)
            }

            self.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deckSurface, in: ShellMetrics.cardShape)
        .overlay {
            ShellMetrics.cardShape.stroke(Color.deckHairline, lineWidth: 0.5)
        }
    }
}
