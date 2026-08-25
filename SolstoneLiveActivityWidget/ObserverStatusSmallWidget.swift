// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

nonisolated struct ObserverStatusPlaceholderEntry: TimelineEntry {
    let date: Date
}

nonisolated struct ObserverStatusPlaceholderTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> ObserverStatusPlaceholderEntry {
        ObserverStatusPlaceholderEntry(date: Date())
    }

    func getSnapshot(in _: Context, completion: @escaping @Sendable (ObserverStatusPlaceholderEntry) -> Void) {
        completion(ObserverStatusPlaceholderEntry(date: Date()))
    }

    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<ObserverStatusPlaceholderEntry>) -> Void) {
        let entry = ObserverStatusPlaceholderEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct ObserverStatusSmallWidget: Widget {
    static let kind = "SolstoneObserverStatusSmall"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ObserverStatusPlaceholderTimelineProvider()) { _ in
            Text("tbd")
        }
        .supportedFamilies([.systemSmall])
    }
}
