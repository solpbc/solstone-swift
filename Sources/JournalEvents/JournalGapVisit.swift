// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// One continuous showing of the status content while the scene is active.
///
/// It starts when that content becomes visible with the scene active, or when the scene
/// becomes active with the content visible. It ends when the content stops showing or the
/// scene leaves active. A rotation, a size-class change, or a split-view resize does not
/// end it while that content is still showing. Hiding the content, with nothing to carry it,
/// ends it. The start marks the unseen losses then on screen, and those stay displayed.
/// A loss that appears during the visit stays on screen and unmarked until the next visit.
/// An empty start marks nothing.
@MainActor
@Observable
final class JournalGapVisit {
    /// True for the whole visit, including one that started with nothing to mark.
    private(set) var didCapture = false
    private(set) var captured: [JournalEventRecord] = []
    /// Bumped by every request and every end, so only the newest request may mark.
    private var generation = 0

    /// The one way a visit starts. `isShowing` reports whether the scene is active and the status
    /// content is visible; it is read before the refresh and again after it. A request whose content
    /// stopped showing during the refresh, or that a newer request or an end superseded, marks nothing.
    /// `fresh` starts a new visit; otherwise a visit starts only when none is underway.
    func requestStart(
        fresh: Bool,
        isShowing: () -> Bool,
        refresh: () async -> Void,
        live: () -> [JournalEventRecord],
        store: JournalEventStore
    ) async {
        guard isShowing() else { return }
        self.generation &+= 1
        let token = self.generation
        await refresh()
        guard token == self.generation, isShowing(), !Task.isCancelled else { return }
        if fresh {
            self.beginNewVisit(live: live(), store: store)
        } else {
            self.captureIfNeeded(live: live(), store: store)
        }
    }

    func beginNewVisit(live: [JournalEventRecord], store: JournalEventStore) {
        self.end()
        self.start(live: live, store: store)
    }

    /// The scene became active while the surface is up. That starts a new visit.
    func foreground(live: [JournalEventRecord], store: JournalEventStore) {
        self.beginNewVisit(live: live, store: store)
    }

    /// The scene left active. Nothing is marked.
    func background() {
        self.end()
    }

    /// Starts a visit when none is in progress. A visit already underway does not mark arrivals.
    func captureIfNeeded(live: [JournalEventRecord], store: JournalEventStore) {
        guard !self.didCapture else { return }
        self.start(live: live, store: store)
    }

    func end() {
        self.generation &+= 1
        self.didCapture = false
        self.captured = []
    }

    func displayed(live: [JournalEventRecord]) -> [JournalEventRecord] {
        guard self.didCapture else { return [] }
        var rows = self.captured
        let seen = Set(rows.map(\.id))
        for loss in live where !seen.contains(loss.id) {
            rows.append(loss)
        }
        return rows
    }

    func displayedNotice(live: [JournalEventRecord], now: Date, calendar: Calendar = .current) -> JournalGapNotice {
        let rows = self.displayed(live: live)
        guard !rows.isEmpty else { return .absent }
        return .showing(dayLine: JournalGapNotice.dayLine(for: rows, now: now, calendar: calendar), losses: rows)
    }

    private func start(live: [JournalEventRecord], store: JournalEventStore) {
        self.didCapture = true
        var kept: [JournalEventRecord] = []
        for loss in live {
            do {
                try store.markSeen(id: loss.id)
                kept.append(loss)
            } catch {
                continue
            }
        }
        self.captured = kept
    }
}
