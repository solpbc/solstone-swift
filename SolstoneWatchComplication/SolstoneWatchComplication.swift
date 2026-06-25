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
        .configurationDisplayName("solstone")
        .description(SourceVocabulary.watchSourceDisplayName)
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct SolstoneWatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot
}

struct SolstoneWatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> SolstoneWatchComplicationEntry {
        SolstoneWatchComplicationEntry(date: Date(), snapshot: Self.fallbackSnapshot)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (SolstoneWatchComplicationEntry) -> Void
    ) {
        completion(SolstoneWatchComplicationEntry(date: Date(), snapshot: Self.loadSnapshot()))
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
    static var fallbackSnapshot: WatchComplicationSnapshot {
        WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(
                status: .off,
                queuedCount: 0,
                transferringCount: 0,
                handedOffCount: 0,
                isSessionRunning: false,
                sessionStartedAt: nil
            ),
            isReachable: false
        )
    }

    static func loadSnapshot() -> WatchComplicationSnapshot {
        do {
            let url = try AppGroupContainer.rootURL()
                .appendingPathComponent(WatchComplicationSnapshot.fileName, isDirectory: false)
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
        } catch {
            return Self.fallbackSnapshot
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
    var snapshot: WatchComplicationSnapshot {
        self.entry.snapshot
    }

    var rectangularView: some View {
        HStack(alignment: .center, spacing: 6) {
            SolstoneComplicationMark(role: self.snapshot.role)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.snapshot.stateWord)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                self.rectangularDetail
            }
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityText)
    }

    @ViewBuilder
    var rectangularDetail: some View {
        if self.snapshot.showsElapsed, let start = self.snapshot.sessionStartedAt {
            Text(start, style: .timer)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if let handoffLine = self.snapshot.handoffLine {
            Text(handoffLine)
                .font(.caption2)
                .foregroundStyle(self.handoffColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let handoffSubtext = self.snapshot.handoffSubtext {
                Text(handoffSubtext)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else if let trustLine = self.snapshot.trustLine {
            Text(trustLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }

    var circularView: some View {
        SolstoneComplicationMark(role: self.snapshot.role)
            .containerBackground(.clear, for: .widget)
            .accessibilityLabel(self.accessibilityText)
    }

    var inlineView: some View {
        Text("solstone · \(self.snapshot.handoffLine ?? self.snapshot.stateWord)")
            .accessibilityLabel(self.accessibilityText)
    }

    var handoffColor: Color {
        guard let role = self.snapshot.handoffRole else {
            return .primary
        }
        return WatchComplicationPalette.color(for: role)
    }

    var accessibilityText: String {
        var parts = ["solstone", self.snapshot.stateWord]
        if let handoffLine = self.snapshot.handoffLine {
            parts.append(handoffLine)
        }
        if let handoffSubtext = self.snapshot.handoffSubtext {
            parts.append(handoffSubtext)
        }
        return parts.joined(separator: ", ")
    }
}

struct SolstoneComplicationMark: View {
    let role: WatchFaceColorRole

    var body: some View {
        Circle()
            .fill(WatchComplicationPalette.color(for: self.role))
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
