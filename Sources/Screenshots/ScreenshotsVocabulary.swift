// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner copy for the screenshots source, keyed to the locked ids.
/// Strings shared with calendar are read from calendar's constants.
nonisolated enum ScreenshotsVocabulary {
    /// S1
    static let label = "screenshots"
    /// S2
    static let activeSubtextPaired = "adds the screenshots you take to your journal while this is on."
    /// S3
    static let activeSubtextUnpaired = "the screenshots you take wait on this device until you connect a journal."
    /// S7
    static let spanHeader = CalendarVocabulary.spanHeader
    /// S9
    static let spanFootnote = "you'll see how many screenshots there are before any come in."
    /// S11
    static let readyToSetUpSubline = "choose how far back to start, then bring them in."
    /// S12
    static let countFailed = "couldn't count your screenshots."
    /// S14
    static let staysIfDeletedFromPhotos = "a screenshot already in your journal stays there if you delete it from Photos."
    /// S15
    static let keepsWhatsIn = "what's already in your journal stays when you pause or turn this off."
    /// S16
    static let pausedSubtext = "you paused this. screenshots you take while it's paused don't come in."
    /// S17
    static let alreadyInJournal = "screenshots already in your journal aren't brought in again."
    /// S18
    static let lastCheckedLabel = "last checked"
    /// S19
    static let waitingLabel = "waiting to go to your journal"
    /// S21
    static let waitingForJournalUpdate = "waiting for a journal update. your screenshots wait on this device."
    /// I1
    static let whatItTakesIn = "while this is on, the solstone app takes in only the screenshots you take, and your journal keeps each one at the minute you took it."
    /// I3
    static let turnOn = "turn on screenshots"
    /// I4
    static let turnOnHint = "asks ios for access to your photos."
    /// I5
    static let honestyLine = "ios lets the solstone app look for new screenshots only while it runs, so one can take a while to reach your journal."
    /// I6
    static let limitedAtPrompt = "ios is sharing only the photos you picked, so new screenshots can't come in. allow full access in ios settings to turn this on."
    /// I7
    static let limitedTile = "photo access is limited to the photos you picked."
    /// I8
    static let limitedPage = "ios is sharing only the photos you picked, so new screenshots can't come in. allow full access in ios settings."
    /// I9
    static let accessOffTile = "photo access is off."
    /// I10
    static let accessOffPage = "photo access is off in ios settings, so nothing new comes in. what's already in your journal stays."
    /// I11
    static let declined = "the solstone app can't read your photos. allow full access in ios settings to turn this on."
    /// I12
    static let restricted = "photos are turned off for the solstone app by a restriction on this device."
    /// I13
    static let photosUsage = "the solstone app takes in only your screenshots and adds them to your journal. other photos stay where they are."
    /// I14
    static let refusedType = "this screenshot is in a format your journal can't keep, so it stays in photos."
    /// I15
    static let tooBig = "this screenshot is too big to come in, so it stays in photos."
    /// I16
    static let couldntCopy = "this screenshot couldn't be copied."
    /// I17
    static let couldntComeIn = "this screenshot couldn't come in."
    /// M3
    static let importLine = "screenshots come in on their own."
    static let setUpScreenshots = "set up screenshots"
    static let openScreenshots = "open screenshots"
    static let tryAgain = "try again"
    static let startFromToday = CalendarVocabulary.startFromToday

    static let spanOrder: [ScreenshotsSpan] = [.last30Days, .last6Months, .lastYear, .everything, .fromToday]

    static func spanLabel(_ span: ScreenshotsSpan) -> String {
        CalendarVocabulary.spanLabel(span.calendar)
    }

    static func activeSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? self.activeSubtextPaired : self.activeSubtextUnpaired
    }

    /// S5 on the tile, S6 on the page.
    static func progress(done: Int, total: Int, onPage: Bool) -> String {
        onPage ? "\(done) of \(total) screenshots in your journal" : "\(done) of \(total) in your journal"
    }

    /// S10. `start from today` for that choice, or a count of zero.
    static func confirmTitle(span: ScreenshotsSpan, count: Int) -> String {
        if span == .fromToday || count == 0 {
            return self.startFromToday
        }
        return count == 1 ? "bring in 1 screenshot" : "bring in \(count) screenshots"
    }

    static func importAction(isOn: Bool) -> String {
        isOn ? self.openScreenshots : self.setUpScreenshots
    }

    static func finalMessage(_ phase: ScreenshotsPhase) -> String? {
        switch phase {
        case .refusedType: self.refusedType
        case .tooBig: self.tooBig
        case .unreadable: self.couldntCopy
        case .journalRefused: self.couldntComeIn
        case .pending, .queued, .delivered, .deleted: nil
        }
    }

    static func finalCanRetry(_ phase: ScreenshotsPhase) -> Bool {
        switch phase {
        case .unreadable, .journalRefused: true
        case .pending, .queued, .delivered, .deleted, .refusedType, .tooBig: false
        }
    }
}
