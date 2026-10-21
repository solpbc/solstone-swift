// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The calendar source's own words. Where the source shares words with location (pause and
/// resume, `open ios settings`, the state words, the block titles `state`, `recent` and `on
/// its way`, the quiet delivery line and the checking word), it uses location's.
nonisolated enum CalendarVocabulary {
    static let label = SourceVocabulary.calendarTitle
    static let valueLinePaired = "the events on your calendar, kept in your journal, yours alone."
    static let valueLineUnpaired = "the events on your calendar. they stay on this device until you connect a journal."
    static let spanHeader = "from before today"
    static let spanFootnote = "you'll see how many events there are before any come in."
    static let turnOn = "turn on calendar"
    static let calendarsHeader = "which calendars"
    static let startFromToday = "start from today"
    static let readyToSetUpSubline = "keep the calendars you want, then bring them in."
    static let activeSubtextPaired = "adds what's on your calendar to your journal while this is on."
    static let activeSubtextUnpaired = "what's on your calendar waits on this device until you connect a journal."
    static let honestyLine = "ios lets the solstone app check your calendar only while it runs, so a change can take a while to reach your journal."
    static let accessRevoked = "calendar access is off in ios settings, so nothing new comes in. what's already in your journal stays."
    static let writeOnly = "calendar access is set to adding events only, so the solstone app can't read it. allow full access in ios settings to keep your journal up to date."
    static let restricted = "calendar is turned off for the solstone app by a restriction on this device."
    static let waitingForJournalUpdate = "your journal needs an update before calendar events can go to it. they wait on this device until then."
    static let countFailed = "couldn't count your calendar events."
    static let tryAgain = "try again"
    static let calendarsBlockTitle = "calendars"
    static let cannotRead = "the solstone app can't read your calendar. allow full access in ios settings to turn this on."
    static let notNow = "not now"
    static let turnOnHint = "asks ios for access to your calendars."
    static let confirmHint = "starts adding calendar events to your journal."
    static let calendarSwitchHint = "includes this calendar's events in your journal."
    static let pauseHint = "pauses calendar updates to your journal."
    static let resumeHint = "resumes calendar updates to your journal."

    static func spanLabel(_ span: CalendarSpanChoice) -> String {
        switch span {
        case .last30Days: "the last 30 days"
        case .last6Months: "the last 6 months"
        case .lastYear: "the last year"
        case .everything: "all of it"
        case .fromToday: "nothing from before today"
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
        count == 1 ? "bring in 1 event" : "bring in \(count) events"
    }

    static func lastChecked(_ time: String) -> String {
        "last checked \(time)"
    }

    static func recent(_ kind: CalendarRecentKind, title: String) -> String {
        "\(kind.rawValue) · \(title)"
    }

    static func deliverySending(count: Int) -> String {
        count == 1 ? "1 calendar change on the way to your journal." : "\(count) calendar changes on the way to your journal."
    }

    static func deliveryNeedsAttention(count: Int) -> String {
        count == 1 ? "1 calendar change needs attention." : "\(count) calendar changes need attention."
    }

    static func followed(_ followed: Int, of total: Int) -> String {
        total == 1 ? "\(followed) of 1 calendar on" : "\(followed) of \(total) calendars on"
    }
}
