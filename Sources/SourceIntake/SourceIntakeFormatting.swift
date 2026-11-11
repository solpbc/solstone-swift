// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceIntakeSource: String, Equatable, Sendable, CaseIterable {
    case audio
    case location
    case screen
    case calendar
    case safari
    case watch
    case obsidian
    case screenshots
    case imports
}

nonisolated enum SourceIntakeKind: Equatable, Sendable {
    case duration
    case distance
    case events
    case pages
    case items
    case notes
    case screenshots
}

nonisolated enum SourceIntakePhrases {
    static let soFar = "so far"
    static let lastTakenIn = "last taken in"
    static let nothingYet = "nothing yet"
    static let lessThanAMinute = "less than a minute"
    static let lessThanAMile = "less than a mile"
    static let lessThanAKilometer = "less than a kilometer"
    static let justNow = "just now"
    static let yesterday = "yesterday"

    static let months = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]
}

nonisolated enum SourceIntakeFormat {
    static let mileMetres = 1609.344
    static let kilometerMetres = 1000.0

    static func total(_ lane: SourceIntakeLane, kind: SourceIntakeKind, locale: Locale) -> String {
        switch kind {
        case .duration:
            return self.duration(lane.total, locale: locale)
        case .distance:
            return self.distance(lane.total, locale: locale)
        case .events:
            return self.count(lane.total, singular: "event", plural: "events", locale: locale)
        case .pages:
            return self.count(lane.total, singular: "page", plural: "pages", locale: locale)
        case .items:
            return self.count(lane.total, singular: "item", plural: "items", locale: locale)
        case .notes:
            return self.count(lane.total, singular: "note", plural: "notes", locale: locale)
        case .screenshots:
            return self.count(lane.total, singular: "screenshot", plural: "screenshots", locale: locale)
        }
    }

    static func started(_ stored: String, now: Date, calendar: Calendar) -> String {
        let parts = stored.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              SourceIntakePhrases.months.indices.contains(month - 1) else {
            return stored
        }
        let name = SourceIntakePhrases.months[month - 1]
        if calendar.component(.year, from: now) == year {
            return "\(name) \(day)"
        }
        return "\(name) \(day), \(year)"
    }

    static func relative(_ date: Date, now: Date, calendar: Calendar) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 {
            return SourceIntakePhrases.justNow
        }
        if elapsed < 3_600 {
            return "\(Int(elapsed / 60)) min ago"
        }
        if elapsed < 86_400 {
            let hours = Int(elapsed / 3_600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let today = calendar.startOfDay(for: now)
        let then = calendar.startOfDay(for: date)
        if let previous = calendar.date(byAdding: .day, value: -1, to: today), then == previous {
            return SourceIntakePhrases.yesterday
        }
        return self.started(self.dayString(date, calendar: calendar), now: now, calendar: calendar)
    }

    static func page(lane: SourceIntakeLane, kind: SourceIntakeKind, started: String, now: Date, locale: Locale, calendar: Calendar) -> (soFar: String, lastTakenIn: String?) {
        guard lane.last != nil else {
            return (SourceIntakePhrases.nothingYet, nil)
        }
        let total = self.total(lane, kind: kind, locale: locale)
        let since = self.started(started, now: now, calendar: calendar)
        let relative = lane.last.map { self.relative($0, now: now, calendar: calendar) }
        return ("\(total), since \(since)", relative)
    }

    static func status(lane: SourceIntakeLane, kind: SourceIntakeKind, now: Date, locale: Locale, calendar: Calendar) -> (soFar: String, last: String) {
        guard let last = lane.last else {
            return (SourceIntakePhrases.nothingYet, SourceIntakePhrases.nothingYet)
        }
        return (
            self.total(lane, kind: kind, locale: locale),
            self.relative(last, now: now, calendar: calendar)
        )
    }

    static func duration(_ seconds: Int, locale: Locale) -> String {
        if seconds < 60 { return SourceIntakePhrases.lessThanAMinute }
        if seconds < 3_600 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(self.grouped(minutes, locale: locale)) minutes"
        }
        let hours = seconds / 3_600
        return hours == 1 ? "1 hour" : "\(self.grouped(hours, locale: locale)) hours"
    }

    static func distance(_ metres: Int, locale: Locale) -> String {
        let metric = locale.measurementSystem == .metric
        let unit = metric ? Self.kilometerMetres : Self.mileMetres
        let whole = Int((Double(metres) / unit).rounded(.down))
        if whole < 1 {
            return metric ? SourceIntakePhrases.lessThanAKilometer : SourceIntakePhrases.lessThanAMile
        }
        if metric {
            return whole == 1 ? "1 kilometer" : "\(self.grouped(whole, locale: locale)) kilometers"
        }
        return whole == 1 ? "1 mile" : "\(self.grouped(whole, locale: locale)) miles"
    }

    static func count(_ total: Int, singular: String, plural: String, locale: Locale) -> String {
        if total == 1 { return "1 \(singular)" }
        return "\(self.grouped(total, locale: locale)) \(plural)"
    }

    static func grouped(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

nonisolated extension SourceIntakeSource {
    var kind: SourceIntakeKind {
        switch self {
        case .audio, .screen, .watch: .duration
        case .location: .distance
        case .calendar: .events
        case .safari: .pages
        case .obsidian: .notes
        case .screenshots: .screenshots
        case .imports: .items
        }
    }
}

nonisolated extension SourceIntakeSnapshot {
    func lane(_ source: SourceIntakeSource) -> SourceIntakeLane {
        switch source {
        case .audio: self.audio
        case .location: self.location
        case .screen: self.screen
        case .calendar: self.calendar
        case .safari: self.safari
        case .watch: self.watch
        case .obsidian: self.obsidian
        case .screenshots: self.screenshots
        case .imports: self.imports
        }
    }
}

nonisolated enum SourceIntakeSample {
    /// 2026-11-09 18:00:00 UTC. Sample relatives are computed from this instant.
    static let now = Date(timeIntervalSince1970: 1_794_247_200)

    static func snapshot(now: Date = SourceIntakeSample.now) -> SourceIntakeSnapshot {
        SourceIntakeSnapshot(
            started: "2026-03-03",
            audio: SourceIntakeLane(total: 5_400, last: now.addingTimeInterval(-600)),
            screen: SourceIntakeLane(total: 120, last: now.addingTimeInterval(-3_600)),
            location: SourceIntakeLane(total: 20_000, last: now.addingTimeInterval(-7_200)),
            calendar: SourceIntakeLane(total: 1, last: now.addingTimeInterval(-86_400 - 3_600)),
            safari: SourceIntakeLane(total: 12, last: now.addingTimeInterval(-30)),
            watch: SourceIntakeLane(total: 40 * 60, last: now.addingTimeInterval(-50)),
            obsidian: SourceIntakeLane(total: 0, last: nil),
            imports: SourceIntakeLane(total: 3, last: now.addingTimeInterval(-120))
        )
    }
}
