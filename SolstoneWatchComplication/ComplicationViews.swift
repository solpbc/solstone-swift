// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import WidgetKit

struct SolstoneWatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot?
}

/// The fallback refresh floor for the one status widget.
///
/// 🔒 **This is a safety net, not the refresh path.** State changes reach the widget through
/// `WidgetCenter.reloadTimelines(ofKind:)` in `WatchCaptureModel`, in seconds. This floor exists
/// only so a *dropped* reload — budget exhausted, the post-launch throttle, or the app suspended
/// or killed before it fires — self-heals instead of freezing.
///
/// ⛔ The timeline used to be `policy: .never`, which has no clock fallback at all: WidgetKit
/// never asks again until the app asks it to. The owner-visible failure that allowed is the worst
/// one this product can ship — the card stuck reading `on` after a crash, with no mechanism to
/// ever correct itself.
///
/// ⚠ 30 minutes is chosen against the documented reload budget (roughly 40–70 per widget per
/// rolling 24h), which this floor alone consumes 48 of. Shortening it spends budget the
/// app-driven path needs and buys nothing in the common case.
nonisolated enum SolstoneWatchComplicationRefresh {
    static let reloadInterval: TimeInterval = 30 * 60

    static func nextReloadDate(after now: Date) -> Date {
        now.addingTimeInterval(self.reloadInterval)
    }
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

        var parts = ["solstone", snapshot.stateWord]
        if let handoffLine = snapshot.handoffLine {
            parts.append(handoffLine)
        }
        if let handoffSubtext = snapshot.handoffSubtext {
            parts.append(handoffSubtext)
        }
        return parts.joined(separator: ", ")
    }
}
