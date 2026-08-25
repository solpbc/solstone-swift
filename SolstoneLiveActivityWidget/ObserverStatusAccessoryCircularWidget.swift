// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct ObserverStatusAccessoryCircularWidget: Widget {
    static let kind = "SolstoneObserverStatusAccessoryCircular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ObserverStatusStaticTimelineProvider()) { entry in
            ObserverStatusAccessoryCircularView(entry: entry)
        }
        .supportedFamilies([.accessoryCircular])
    }
}

private struct ObserverStatusAccessoryCircularView: View {
    let entry: ObserverStatusTimelineEntry

    var body: some View {
        if self.entry.isPlaceholder {
            Image(systemName: "questionmark.circle")
                .redacted(reason: .placeholder)
        } else {
            self.content
        }
    }

    private var presentation: ObserverStatusPresentation {
        ObserverStatusPresentations.circular(for: self.entry)
    }

    private var content: some View {
        VStack(spacing: 1) {
            Image(systemName: self.presentation.symbol)
                .font(.caption)

            if let count = self.presentation.count {
                Text("\(count)")
                    .font(.headline.monospacedDigit())
                    .invalidatableContent()
                Text(self.entry.date, style: .relative)
                    .font(.caption2)
                    .lineLimit(1)
            } else {
                Text(self.presentation.label)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(11)
        .accessibilityLabel(self.presentation.label)
    }
}
