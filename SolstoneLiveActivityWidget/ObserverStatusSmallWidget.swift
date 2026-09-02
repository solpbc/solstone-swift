// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct ObserverStatusSmallWidget: Widget {
    static let kind = "SolstoneObserverStatusSmall"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: ObserverWidgetConfigurationIntent.self,
            provider: ObserverStatusSmallTimelineProvider()
        ) { entry in
            ObserverStatusSmallView(entry: entry)
        }
        .supportedFamilies([.systemSmall])
        .configurationDisplayName("one source")
        .description("pick a source and see its state.")
    }
}

private struct ObserverStatusSmallView: View {
    let entry: ObserverStatusTimelineEntry

    var body: some View {
        if self.entry.isPlaceholder {
            self.placeholder
        } else {
            self.content
        }
    }

    private var presentation: ObserverStatusPresentation {
        ObserverStatusPresentations.small(for: self.entry)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.title2)
            Text("audio")
                .font(.headline)
            Text("waiting to sync")
                .font(.caption)
        }
        .redacted(reason: .placeholder)
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: self.presentation.symbol)
                    .font(.title2)
                if let sourceName = self.sourceName {
                    Text(sourceName)
                        .font(.headline)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(self.presentation.label)
                .font(.caption.weight(.semibold))
                .lineLimit(2)

            if let count = self.presentation.count {
                Text("\(count)")
                    .font(.title.monospacedDigit().weight(.bold))
                    .invalidatableContent()
                Text(self.entry.date, style: .relative)
                    .font(.caption2)
            } else {
                Text(self.entry.date, style: .relative)
                    .font(.caption2)
            }
        }
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var sourceName: String? {
        switch self.entry.sourceKind {
        case .observer:
            // ⛔ Not "observer". That is the internal name for this source; the owner-facing
            // one has been `audio` since 2026-07-03, and this widget renders on a home screen.
            SourceVocabulary.onThisPhoneSourceName(for: .audio)
        case .location:
            "location"
        case .omi:
            "omi"
        case .screencast:
            SourceVocabulary.screencastDisplayName
        case .watch, nil:
            nil
        }
    }
}
