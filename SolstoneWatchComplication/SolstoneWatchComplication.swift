// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import RelevanceKit
import SwiftUI
import WidgetKit

/// 🔒 **ONE widget. Do not add a second one for the Smart Stack.**
///
/// A `SolstoneWatchStatusSmartStackWidget` used to sit here, added on the premise that the Smart
/// Stack needs a widget of its own. It does not — per WWDC23 session 10029, the
/// `.accessoryRectangular` view *is* the view shown in the watchOS Smart Stack, and
/// `SolstoneWatchComplication` already declares that family. The second widget rendered the same
/// view from the same snapshot and bought nothing.
///
/// What it cost was three things. It put **two entries both labelled "solstone"** in the watch's
/// widget picker, which is what the owner sees and cannot tell apart. It was **never reloaded** —
/// `reloadTimelines(ofKind:)` matches `kind` exactly and every call site passes
/// `WatchComplicationSnapshot.widgetKind`, so the Smart Stack card could sit half an hour stale.
/// And its kind, `SolstoneWatchStatusSmartStack`, had `SolstoneWatchStatus` as a **strict
/// prefix** — WidgetKit persists per-widget state in a path keyed by `kind`, and that is the
/// leading explanation for the widget rendering correctly in the gallery yet failing to persist
/// into the Smart Stack when added.
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
        completion(Timeline(
            entries: entries,
            policy: .after(SolstoneWatchComplicationRefresh.nextReloadDate(after: now))
        ))
    }

    /// Tells the Smart Stack this card is worth showing **while audio is actually being taken in.**
    ///
    /// Without this the card can only ever sit wherever the owner dragged it: `TimelineProvider`
    /// ships a default `relevance()` returning nothing, so the system has no reason to rotate us
    /// up at the one moment the card is worth anything. Relevance does not gate whether the
    /// widget can be added — it gates whether it ever surfaces on its own.
    ///
    /// ⚠ **There is no "my app is recording" relevance context, and that is the whole design
    /// constraint here.** `RelevantContext` offers date, location, sleep, fitness and headphones —
    /// nothing about an app's own session. So a live session is expressed as a **rolling date
    /// window**: relevant from now until the audio-verification horizon measured from the last
    /// verified audio, republished every time
    /// state changes via `invalidateRelevance(ofKind:)`. While capture continues the window keeps
    /// moving forward; when capture stops, the next invalidation publishes nothing and the boost
    /// ends on its own.
    ///
    /// ⛔ Deliberately silent when capture is off. A listening indicator that promotes itself
    /// while not listening is worse than one that stays put.
    func relevance() async -> WidgetRelevance<Void> {
        guard let window = watchComplicationRelevanceWindow(
            snapshot: WatchComplicationSnapshotSource.load(),
            now: Date()
        ) else {
            return WidgetRelevance([])
        }

        return WidgetRelevance([
            WidgetRelevanceAttribute(context: .date(range: window, kind: .default)),
        ])
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
