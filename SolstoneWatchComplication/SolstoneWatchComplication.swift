// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

@main
struct SolstoneWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        SolstoneWatchComplication()
        SolstoneWatchStatusSmartStackWidget()
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

struct SolstoneWatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> SolstoneWatchComplicationEntry {
        SolstoneWatchComplicationEntry(
            date: Date(),
            snapshot: context.isPreview ? WatchComplicationSnapshotSource.previewSnapshot : nil
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (SolstoneWatchComplicationEntry) -> Void
    ) {
        completion(
            SolstoneWatchComplicationEntry(
                date: Date(),
                snapshot: context.isPreview ? WatchComplicationSnapshotSource.previewSnapshot : WatchComplicationSnapshotSource.load()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SolstoneWatchComplicationEntry>) -> Void
    ) {
        let now = Date()
        let entries = watchComplicationTimelinePoints(snapshot: WatchComplicationSnapshotSource.load(), now: now).map { point in
            SolstoneWatchComplicationEntry(date: point.date, snapshot: point.snapshot)
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct SolstoneWatchStatusSmartStackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SolstoneWatchStatusSmartStack.widgetKind,
            provider: SolstoneWatchStatusSmartStackProvider()
        ) { entry in
            SolstoneWatchComplicationView(entry: entry)
        }
        .configurationDisplayName("solstone")
        .description(SourceVocabulary.watchSourceDisplayName)
        .supportedFamilies([.accessoryRectangular])
    }
}

struct SolstoneWatchStatusSmartStackProvider: TimelineProvider {
    func placeholder(in context: Context) -> SolstoneWatchComplicationEntry {
        SolstoneWatchComplicationEntry(
            date: Date(),
            snapshot: context.isPreview ? WatchComplicationSnapshotSource.previewSnapshot : nil
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (SolstoneWatchComplicationEntry) -> Void
    ) {
        completion(
            SolstoneWatchComplicationEntry(
                date: Date(),
                snapshot: context.isPreview ? WatchComplicationSnapshotSource.previewSnapshot : WatchComplicationSnapshotSource.load()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SolstoneWatchComplicationEntry>) -> Void
    ) {
        let now = Date()
        let entry = SolstoneWatchComplicationEntry(
            date: now,
            snapshot: WatchComplicationSnapshotSource.load()
        )
        completion(Timeline(
            entries: [entry],
            policy: .after(SolstoneWatchStatusSmartStack.nextReloadDate(after: now))
        ))
    }
}

private enum WatchComplicationSnapshotSource {
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

    static func load() -> WatchComplicationSnapshot? {
        do {
            return loadWatchComplicationSnapshot(from: try AppGroupContainer.rootURL())
        } catch {
            return nil
        }
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
