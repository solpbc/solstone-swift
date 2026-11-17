// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The calendar source's own words. Where the source shares words with location (pause and
/// resume, `open ios settings`, the state words, the block titles `state`, `recent` and `on
/// its way`, the quiet delivery line and the checking word), it uses location's.
nonisolated enum CalendarVocabulary {
    static let label = SourceVocabulary.calendarTitle
    static let valueLinePaired = AppStrings.ios_calendar_valuelinepaired()
    static let valueLineUnpaired = AppStrings.ios_calendar_valuelineunpaired()
    static let spanHeader = AppStrings.ios_calendar_spanheader()
    static let spanFootnote = AppStrings.ios_calendar_spanfootnote()
    static let turnOn = AppStrings.ios_calendar_turnon()
    static let calendarsHeader = AppStrings.ios_calendar_calendarsheader()
    static let startFromToday = AppStrings.ios_calendar_startfromtoday()
    static let readyToSetUpSubline = AppStrings.ios_calendar_readytosetupsubline()
    static let activeSubtextPaired = AppStrings.ios_calendar_activesubtextpaired()
    static let activeSubtextUnpaired = AppStrings.ios_calendar_activesubtextunpaired()
    static let honestyLine = AppStrings.ios_calendar_honestyline()
    static let accessRevoked = AppStrings.ios_calendar_accessrevoked()
    static let writeOnly = AppStrings.ios_calendar_writeonly()
    static let restricted = AppStrings.ios_calendar_restricted()
    static let waitingForJournalUpdate = AppStrings.ios_calendar_waitingforjournalupdate()
    static let countFailed = AppStrings.ios_calendar_countfailed()
    static let tryAgain = AppStrings.ios_migration_offline_action()
    static let calendarsBlockTitle = AppStrings.ios_calendar_calendarsblocktitle()
    /// Pausing or switching a calendar off removes nothing that already came in.
    static let keepsWhatsIn = AppStrings.ios_calendar_keepswhatsin()
    static let cannotRead = AppStrings.ios_calendar_cannotread()
    static let notNow = AppStrings.ios_migration_choice_defer()
    static let turnOnHint = AppStrings.ios_calendar_turnonhint()
    static let confirmHint = AppStrings.ios_calendar_confirmhint()
    static let calendarSwitchHint = AppStrings.ios_calendar_calendarswitchhint()
    static let pauseHint = AppStrings.ios_calendar_pausehint()
    static let resumeHint = AppStrings.ios_calendar_resumehint()

    static func spanLabel(_ span: CalendarSpanChoice) -> String {
        switch span {
        case .last30Days: AppStrings.ios_calendar_span_native()
        case .last6Months: AppStrings.ios_calendarvocabulary_thelast6months()
        case .lastYear: AppStrings.ios_calendarvocabulary_thelastyear()
        case .everything: AppStrings.ios_calendarvocabulary_allofit()
        case .fromToday: AppStrings.ios_calendarvocabulary_nothingfrombeforetoday()
        }
    }

    /// The order the span choices are offered in; the first is preselected.
    static let spanOrder: [CalendarSpanChoice] = [.last30Days, .last6Months, .lastYear, .everything, .fromToday]

    static func valueLine(isJournalPaired: Bool) -> String {
        isJournalPaired ? self.valueLinePaired : self.valueLineUnpaired
    }

    static func activeSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? self.activeSubtextPaired : self.activeSubtextUnpaired
    }

    /// `bring in {N} events`, singular `bring in 1 event`.
    static func bringIn(count: Int) -> String {
        AppStrings.ios_plural_calendarvocabulary_n62(count, "\(count)")
    }

    static func lastChecked(_ time: String) -> String {
        AppStrings.ios_calendar_lastchecked("\(time)")
    }

    /// The time of the last check, with its date when that was not today.
    static func lastCheckedTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// An event with no title shows the change word alone.
    static func recent(_ kind: CalendarRecentKind, title: String?) -> String {
        let word: String
        switch kind {
        case .added: word = AppStrings.ios_calendar_recent_added()
        case .moved: word = AppStrings.ios_calendar_recent_moved()
        case .changed: word = AppStrings.ios_calendar_recent_changed()
        case .removed: word = AppStrings.ios_calendar_recent_removed()
        }
        guard let title, !title.isEmpty else { return word }
        return AppStrings.ios_calendar_recent_title(word, title)
}

    static func deliverySending(count: Int) -> String {
        AppStrings.ios_plural_calendarvocabulary_n83(count, "\(count)")
    }

    static func deliveryNeedsAttention(count: Int) -> String {
        AppStrings.ios_plural_calendarvocabulary_n87(count, "\(count)")
    }

    static func followed(_ followed: Int, of total: Int) -> String {
        AppStrings.ios_plural_calendarvocabulary_n91(total, "\(followed)", "\(total)")
    }
}
