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
    case photos
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
    case photos
}

nonisolated enum SourceIntakePhrases {
    static let soFar = AppStrings.ios_sourceintakeformatting_sofar()
    static let lastTakenIn = AppStrings.ios_sourceintakeformatting_lasttakenin()
    static let nothingYet = AppStrings.ios_watch_lastfactrows8()
    static let lessThanAMinute = AppStrings.ios_sourceintakeformatting_lessthanaminute()
    static let lessThanAMile = AppStrings.ios_sourceintakeformatting_lessthanamile()
    static let lessThanAKilometer = AppStrings.ios_sourceintakeformatting_lessthanakilometer()
    static let justNow = AppStrings.ios_app_watchrelativejustnow()
    static let yesterday = AppStrings.ios_app_relativedaylabel()

    static let months = [
        AppStrings.ios_sourceintakeformatting_january(), AppStrings.ios_sourceintakeformatting_february(), AppStrings.ios_sourceintakeformatting_march(), AppStrings.ios_sourceintakeformatting_april(), AppStrings.ios_sourceintakeformatting_may(), AppStrings.ios_sourceintakeformatting_june(),
        AppStrings.ios_sourceintakeformatting_july(), AppStrings.ios_sourceintakeformatting_august(), AppStrings.ios_sourceintakeformatting_september(), AppStrings.ios_sourceintakeformatting_october(), AppStrings.ios_sourceintakeformatting_november(), AppStrings.ios_sourceintakeformatting_december(),
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
            return AppStrings.ios_intake_count_events(lane.total, self.grouped(lane.total, locale: locale))
        case .pages:
            return AppStrings.ios_intake_count_pages(lane.total, self.grouped(lane.total, locale: locale))
        case .items:
            return AppStrings.ios_intake_count_items(lane.total, self.grouped(lane.total, locale: locale))
        case .notes:
            return AppStrings.ios_intake_count_notes(lane.total, self.grouped(lane.total, locale: locale))
        case .screenshots:
            return AppStrings.ios_intake_count_screenshots(lane.total, self.grouped(lane.total, locale: locale))
        case .photos:
            return AppStrings.ios_intake_count_photos(lane.total, self.grouped(lane.total, locale: locale))
        }
    }

    static func started(_ stored: String, now: Date, calendar: Calendar) -> String {
        let parts = stored.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              SourceIntakePhrases.months.indices.contains(month - 1) else {
            return stored
        }
        if AppStrings.language != "en-US", let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
            let formatter = DateFormatter()
            formatter.locale = AppStrings.locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: now) == year ? "MMMMd" : "yMMMMd")
            return formatter.string(from: date)
        }
        let name = SourceIntakePhrases.months[month - 1]
        if calendar.component(.year, from: now) == year {
            return AppStrings.ios_intake_date_day(name, String(day))
        }
        return AppStrings.ios_intake_date_year(name, String(day), String(year))
    }

    static func relative(_ date: Date, now: Date, calendar: Calendar) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 {
            return SourceIntakePhrases.justNow
        }
        if elapsed < 3_600 {
            return AppStrings.ios_sourceintakeformatting_minago("\(Int(elapsed / 60))")
        }
        if elapsed < 86_400 {
            let hours = Int(elapsed / 3_600)
            return AppStrings.ios_plural_sourceintakeformatting_n90(hours, "\(hours)")
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
        return (AppStrings.ios_sourceintakeformatting_since("\(total)", "\(since)"), relative)
    }

    /// Before a source takes anything in, the row has no last time: `nothing yet` stands once, across both columns.
    static func status(lane: SourceIntakeLane, kind: SourceIntakeKind, now: Date, locale: Locale, calendar: Calendar) -> (soFar: String, last: String?) {
        guard let last = lane.last else {
            return (SourceIntakePhrases.nothingYet, nil)
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
            return AppStrings.ios_plural_sourceintakeformatting_n124(minutes, "\(self.grouped(minutes, locale: locale))")
        }
        let hours = seconds / 3_600
        return AppStrings.ios_plural_sourceintakeformatting_n127(hours, "\(self.grouped(hours, locale: locale))")
    }

    static func distance(_ metres: Int, locale: Locale) -> String {
        let metric = locale.measurementSystem == .metric
        let unit = metric ? Self.kilometerMetres : Self.mileMetres
        let whole = Int((Double(metres) / unit).rounded(.down))
        if whole < 1 {
            return metric ? SourceIntakePhrases.lessThanAKilometer : SourceIntakePhrases.lessThanAMile
        }
        if metric {
            return AppStrings.ios_plural_sourceintakeformatting_n138(whole, "\(self.grouped(whole, locale: locale))")
        }
        return AppStrings.ios_plural_sourceintakeformatting_n140(whole, "\(self.grouped(whole, locale: locale))")
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
        case .photos: .photos
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
        case .photos: self.photos
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
