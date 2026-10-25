// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The notice the pill, the status, and on-this-device read. Losses only, and only while the gate is open.
nonisolated enum JournalGapNotice: Equatable, Sendable {
    case absent
    case showing(dayLine: String, losses: [JournalEventRecord])

    var isShowing: Bool {
        if case .showing = self { return true }
        return false
    }

    var dayLine: String? {
        if case .showing(let dayLine, _) = self { return dayLine }
        return nil
    }

    var losses: [JournalEventRecord] {
        if case .showing(_, let losses) = self { return losses }
        return []
    }

    var lossIDs: [String] { self.losses.map(\.id) }

    /// Seconds until the next local midnight. At least one second, so a pass that lands on the boundary waits for the next day.
    static func delayUntilNextDay(from now: Date, calendar: Calendar = .current) -> TimeInterval {
        let start = calendar.startOfDay(for: now)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return 1 }
        return max(1, next.timeIntervalSince(now))
    }

    static func read(store: JournalEventStore, now: Date, calendar: Calendar = .current) -> JournalGapNotice {
        switch store.unseenLosses(now: now, calendar: calendar) {
        case .unreadable:
            return .absent
        case .events(let losses):
            guard !losses.isEmpty else { return .absent }
            return .showing(dayLine: Self.dayLine(for: losses, now: now, calendar: calendar), losses: losses)
        }
    }

    /// Day line from the capture days of these losses. A missing capture, or a capture older than the window, uses the undated line.
    static func dayLine(for losses: [JournalEventRecord], now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = JournalEventStore.windowStart(now: now, calendar: calendar) else {
            return SourceVocabulary.journalGapUndated
        }
        var days = Set<Date>()
        for loss in losses {
            guard let captureAt = loss.captureAt else { return SourceVocabulary.journalGapUndated }
            let day = calendar.startOfDay(for: captureAt)
            if day < windowStart { return SourceVocabulary.journalGapUndated }
            days.insert(day)
        }
        guard let only = days.first else { return SourceVocabulary.journalGapUndated }
        if days.count == 1 {
            if only == today { return SourceVocabulary.journalGapToday }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), only == yesterday {
                return SourceVocabulary.journalGapYesterday
            }
            return SourceVocabulary.journalGapOn(weekday: Self.weekdayName(only, calendar: calendar))
        }
        let earliest = days.min() ?? only
        let word: String
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), earliest == yesterday {
            word = "yesterday"
        } else {
            word = Self.weekdayName(earliest, calendar: calendar)
        }
        return SourceVocabulary.journalGapSince(earliest: word)
    }

    private static func weekdayName(_ day: Date, calendar: Calendar) -> String {
        let weekday = calendar.component(.weekday, from: day)
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let index = weekday - 1
        guard names.indices.contains(index) else { return "sunday" }
        return names[index]
    }
}
