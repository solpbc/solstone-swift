// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct ObserverStatusMediumWidget: Widget {
    static let kind = "SolstoneObserverStatusMedium"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ObserverStatusStaticTimelineProvider()) { entry in
            ObserverStatusMediumView(entry: entry)
        }
        .supportedFamilies([.systemMedium])
    }
}

private struct ObserverStatusMediumView: View {
    let entry: ObserverStatusTimelineEntry

    var body: some View {
        if self.entry.isPlaceholder {
            self.placeholder
        } else {
            self.content
        }
    }

    private var presentation: ObserverStatusPresentation {
        ObserverStatusPresentations.medium(for: self.entry)
    }

    private var placeholder: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.title2)
            VStack(alignment: .leading, spacing: 6) {
                Text("tbd")
                    .font(.headline)
                Text("tbd")
                    .font(.caption)
            }
            Spacer()
        }
        .redacted(reason: .placeholder)
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: self.presentation.symbol)
                .font(.title2)

            VStack(alignment: .leading, spacing: 6) {
                Text(self.presentation.label)
                    .font(.headline)
                    .lineLimit(1)

                self.sourceStates

                Text(self.entry.date, style: .relative)
                    .font(.caption2)
            }

            Spacer(minLength: 0)

            if let count = self.presentation.count {
                Text("\(count)")
                    .font(.title.monospacedDigit().weight(.bold))
                    .invalidatableContent()
            }
        }
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var sourceStates: some View {
        HStack(spacing: 6) {
            ForEach(Self.sourceKinds, id: \.self) { sourceKind in
                if let state = self.entry.snapshot?.sourceStates[sourceKind] {
                    Image(systemName: state.symbol)
                        .font(.caption)
                        .accessibilityLabel(state.label)
                }
            }
        }
    }

    private static let sourceKinds: [SourceKind] = [.observer, .location, .omi, .screencast, .watch]
}
