// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Shell-owned visit. Rotation and disappearing views do not start or end it.
/// An already-visible surface does not capture an empty set. The visit starts when that surface first has losses to show.
@MainActor
@Observable
final class JournalGapVisit {
    private(set) var didCapture = false
    private(set) var captured: [JournalEventRecord] = []

    func beginNewVisit(live: [JournalEventRecord], store: JournalEventStore) {
        self.end()
        self.captureIfNeeded(live: live, store: store)
    }

    /// Scene active while the surface is still up. Starts a visit only when none is in progress.
    func foreground(live: [JournalEventRecord], store: JournalEventStore) {
        self.captureIfNeeded(live: live, store: store)
    }

    func captureIfNeeded(live: [JournalEventRecord], store: JournalEventStore) {
        guard !self.didCapture else { return }
        guard !live.isEmpty else { return }
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

    func end() {
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
}
