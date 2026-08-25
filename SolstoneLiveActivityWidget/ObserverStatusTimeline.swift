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

nonisolated enum ObserverStatusPresentation: Equatable, Sendable {
    case unavailable
    case notPaired
    case needsAttention
    case waiting(count: Int)
    case caughtUp

    var label: String {
        switch self {
        case .unavailable:
            SourceVocabulary.screencastUnavailableSubtext
        case .notPaired:
            SourceVocabulary.notPaired
        case .needsAttention:
            SourceVocabulary.needsAttention
        case .waiting:
            SourceVocabulary.waitingToSync
        case .caughtUp:
            SourceVocabulary.syncedHeadline
        }
    }

    var symbol: String {
        switch self {
        case .unavailable:
            "questionmark.circle"
        case .notPaired:
            "questionmark.circle"
        case .needsAttention:
            "exclamationmark.triangle"
        case .waiting:
            "arrow.triangle.2.circlepath"
        case .caughtUp:
            "checkmark.circle"
        }
    }

    var count: Int? {
        guard case let .waiting(count) = self else { return nil }
        return count
    }
}

nonisolated enum ObserverStatusPresentations {
    static func small(for entry: ObserverStatusTimelineEntry) -> ObserverStatusPresentation {
        guard let snapshot = entry.snapshot,
              let sourceKind = entry.sourceKind,
              snapshot.sourceStates[sourceKind] != nil
        else {
            return .unavailable
        }

        guard sourceKind != .watch else {
            return .unavailable
        }

        guard snapshot.pairing.isPaired else {
            return .notPaired
        }

        if snapshot.sourceStates[sourceKind] == .needsAttention {
            return .needsAttention
        }

        if snapshot.backlogCount > 0 {
            return .waiting(count: snapshot.backlogCount)
        }

        return .caughtUp
    }

    static func medium(for entry: ObserverStatusTimelineEntry) -> ObserverStatusPresentation {
        guard let snapshot = entry.snapshot else {
            return .unavailable
        }

        guard snapshot.pairing.isPaired else {
            return .notPaired
        }

        if snapshot.sourceStates.values.contains(.needsAttention) {
            return .needsAttention
        }

        if snapshot.backlogCount > 0 {
            return .waiting(count: snapshot.backlogCount)
        }

        return .caughtUp
    }

    static func circular(for entry: ObserverStatusTimelineEntry) -> ObserverStatusPresentation {
        guard let snapshot = entry.snapshot else {
            return .unavailable
        }

        guard snapshot.pairing.isPaired else {
            return .notPaired
        }

        if snapshot.backlogCount > 0 {
            return .waiting(count: snapshot.backlogCount)
        }

        return .caughtUp
    }
}
