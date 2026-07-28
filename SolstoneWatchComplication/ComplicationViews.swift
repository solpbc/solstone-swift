// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import WidgetKit

struct SolstoneWatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot?
}

struct SolstoneWatchComplicationView: View {
    @Environment(\.widgetFamily) private var family

    let entry: SolstoneWatchComplicationEntry

    var body: some View {
        switch self.family {
        case .accessoryRectangular:
            self.rectangularView
        case .accessoryCircular:
            self.circularView
        case .accessoryInline:
            self.inlineView
        default:
            self.rectangularView
        }
    }
}

private extension SolstoneWatchComplicationView {
    var snapshot: WatchComplicationSnapshot? {
        self.entry.snapshot
    }

    var markAssetName: String {
        watchComplicationMarkAssetName(for: self.snapshot)
    }

    var rectangularView: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(self.markAssetName, bundle: #bundle)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .widgetAccentable()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let snapshot = self.snapshot {
                    Text(snapshot.stateWord)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    self.rectangularDetail(for: snapshot)
                } else {
                    Text(SourceVocabulary.watchComplicationUnknownHeadline)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(SourceVocabulary.watchComplicationUnknownDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityText)
    }

    @ViewBuilder
    func rectangularDetail(for snapshot: WatchComplicationSnapshot) -> some View {
        if snapshot.showsElapsed, let start = snapshot.sessionStartedAt {
            Text(start, style: .timer)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if let handoffLine = snapshot.handoffLine {
            Text(handoffLine)
                .font(.caption2)
                .foregroundStyle(self.handoffColor(for: snapshot.handoffRole))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let handoffSubtext = snapshot.handoffSubtext {
                Text(handoffSubtext)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else if let trustLine = snapshot.trustLine {
            Text(trustLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }

    var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(self.markAssetName, bundle: #bundle)
                .resizable()
                .scaledToFit()
                .padding(1)
                .widgetAccentable()
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel(self.accessibilityText)
    }

    var inlineView: some View {
        Text(watchComplicationInlineText(for: self.snapshot))
            .accessibilityLabel(self.accessibilityText)
    }

    func handoffColor(for role: WatchFaceColorRole?) -> Color {
        guard let role else {
            return .primary
        }
        return WatchComplicationPalette.color(for: role)
    }

    var accessibilityText: String {
        guard let snapshot = self.snapshot else {
            return "\(SourceVocabulary.watchComplicationUnknownHeadline), \(SourceVocabulary.watchComplicationUnknownDetail)"
        }

        var parts = ["sol", snapshot.stateWord]
        if let handoffLine = snapshot.handoffLine {
            parts.append(handoffLine)
        }
        if let handoffSubtext = snapshot.handoffSubtext {
            parts.append(handoffSubtext)
        }
        return parts.joined(separator: ", ")
    }
}
