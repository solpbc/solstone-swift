// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

@main
struct SolstoneWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        SolstoneWatchComplication()
    }
}

struct SolstoneWatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WatchComplicationSnapshot.widgetKind,
            provider: SolstoneWatchComplicationProvider()
        ) { entry in
            SolstoneWatchComplicationView(entry: entry)
        }
        .configurationDisplayName("sol")
        .description(SourceVocabulary.watchSourceDisplayName)
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct SolstoneWatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot?
}

struct SolstoneWatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> SolstoneWatchComplicationEntry {
        SolstoneWatchComplicationEntry(
            date: Date(),
            snapshot: context.isPreview ? Self.previewSnapshot : nil
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (SolstoneWatchComplicationEntry) -> Void
    ) {
        completion(
            SolstoneWatchComplicationEntry(
                date: Date(),
                snapshot: context.isPreview ? Self.previewSnapshot : Self.loadSnapshot()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SolstoneWatchComplicationEntry>) -> Void
    ) {
        let entry = SolstoneWatchComplicationEntry(date: Date(), snapshot: Self.loadSnapshot())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private extension SolstoneWatchComplicationProvider {
    static var previewSnapshot: WatchComplicationSnapshot {
        WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: Date(timeIntervalSinceNow: -180)
            ),
            isReachable: true
        )
    }

    static func loadSnapshot() -> WatchComplicationSnapshot? {
        do {
            let url = try AppGroupContainer.rootURL()
                .appendingPathComponent(WatchComplicationSnapshot.fileName, isDirectory: false)
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
        } catch {
            return nil
        }
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
            Image(self.markAssetName)
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
            Image(self.markAssetName)
                .resizable()
                .scaledToFit()
                .padding(1)
        }
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel(self.accessibilityText)
    }

    @ViewBuilder
    var inlineView: some View {
        if let snapshot = self.snapshot {
            Text("sol · \(snapshot.handoffLine ?? snapshot.stateWord)")
                .accessibilityLabel(self.accessibilityText)
        } else {
            Text("sol · \(SourceVocabulary.watchComplicationUnknownHeadline)")
                .accessibilityLabel(self.accessibilityText)
        }
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

#Preview("listening", as: .accessoryRectangular) {
    SolstoneWatchComplication()
} timeline: {
    SolstoneWatchComplicationEntry(
        date: Date(),
        snapshot: WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .active,
                queuedCount: 0,
                isSessionRunning: true,
                sessionStartedAt: Date(timeIntervalSinceNow: -180)
            ),
            isReachable: true
        )
    )
}

#Preview("off", as: .accessoryCircular) {
    SolstoneWatchComplication()
} timeline: {
    SolstoneWatchComplicationEntry(
        date: Date(),
        snapshot: WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
            isReachable: true
        )
    )
}

#Preview("pending", as: .accessoryInline) {
    SolstoneWatchComplication()
} timeline: {
    SolstoneWatchComplicationEntry(
        date: Date(),
        snapshot: WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 3),
            isReachable: false
        )
    )
}

#Preview("unknown", as: .accessoryCircular) {
    SolstoneWatchComplication()
} timeline: {
    SolstoneWatchComplicationEntry(
        date: Date(),
        snapshot: nil
    )
}
