// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct HomeSourceStateDot: View {
    let state: SourceState
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 10

    var body: some View {
        self.shape
            .frame(width: self.size, height: self.size)
            .foregroundStyle(self.tint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shape: some View {
        switch self.state {
        case .active, .enrolling:
            Circle().fill(self.tint)
        case .off, .paused, .readyToSetUp:
            Circle().strokeBorder(self.tint, lineWidth: 1.5)
        case .checking, .needsAttention:
            ZStack {
                Circle().strokeBorder(self.tint, lineWidth: 1.5)
                Capsule()
                    .fill(self.tint)
                    .frame(width: self.size * 0.7, height: 1.5)
            }
        }
    }

    private var tint: Color {
        switch self.state {
        case .active, .enrolling, .readyToSetUp:
            Color.solOrange
        case .checking, .paused, .off:
            .secondary
        case .needsAttention:
            .red
        }
    }
}
