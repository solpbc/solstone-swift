// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents
import Foundation
import WidgetKit

nonisolated struct ObserverStatusTimelineEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: AppGroupMirror.Snapshot?
    let sourceKind: SourceKind?
    let isPlaceholder: Bool
}

nonisolated struct ObserverStatusSmallTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> ObserverStatusTimelineEntry {
        ObserverStatusTimelineEntry(
            date: Date(),
            snapshot: nil,
            sourceKind: .observer,
            isPlaceholder: true
        )
    }

    func snapshot(
        for configuration: ObserverWidgetConfigurationIntent,
        in _: Context
    ) async -> ObserverStatusTimelineEntry {
        await ObserverStatusTimelineEntry.current(sourceKind: configuration.source.sourceKind)
    }

    func timeline(
        for configuration: ObserverWidgetConfigurationIntent,
        in _: Context
    ) async -> Timeline<ObserverStatusTimelineEntry> {
        let entry = await ObserverStatusTimelineEntry.current(sourceKind: configuration.source.sourceKind)
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Self.refreshInterval)))
    }

    private static let refreshInterval: TimeInterval = 30 * 60
}

nonisolated struct ObserverStatusStaticTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> ObserverStatusTimelineEntry {
        ObserverStatusTimelineEntry(
            date: Date(),
            snapshot: nil,
            sourceKind: nil,
            isPlaceholder: true
        )
    }

    func getSnapshot(
        in _: Context,
        completion: @escaping @Sendable (ObserverStatusTimelineEntry) -> Void
    ) {
        Task {
            completion(await ObserverStatusTimelineEntry.current(sourceKind: nil))
        }
    }

    func getTimeline(
        in _: Context,
        completion: @escaping @Sendable (Timeline<ObserverStatusTimelineEntry>) -> Void
    ) {
        Task {
            let entry = await ObserverStatusTimelineEntry.current(sourceKind: nil)
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Self.refreshInterval))))
        }
    }

    private static let refreshInterval: TimeInterval = 30 * 60
}

private extension ObserverStatusTimelineEntry {
    static func current(sourceKind: SourceKind?) async -> Self {
        let snapshot = await MainActor.run { AppGroupMirror().snapshot() }
        return Self(date: Date(), snapshot: snapshot, sourceKind: sourceKind, isPlaceholder: false)
    }
}

