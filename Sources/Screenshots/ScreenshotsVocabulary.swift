// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner copy for the screenshots source, keyed to the locked ids.
/// Strings shared with calendar are read from calendar's constants.
nonisolated enum ScreenshotsVocabulary {
    /// S1
    static let label = AppStrings.ios_photolibrary_albumscreenshots()
    /// S2
    static let activeSubtextPaired = AppStrings.ios_screenshots_addsthescreenshotsyoutake()
    /// S3
    static let activeSubtextUnpaired = AppStrings.ios_screenshots_thescreenshotsyoutakewait()
    /// S7
    static let spanHeader = CalendarVocabulary.spanHeader
    /// S9
    static let spanFootnote = AppStrings.ios_screenshots_youllseehowmanyscreenshots()
    /// S11
    static let readyToSetUpSubline = AppStrings.ios_screenshots_choosehowfarbackto()
    /// S12
    static let countFailed = AppStrings.ios_screenshots_couldntcountyourscreenshots()
    /// S14
    static let staysIfDeletedFromPhotos = AppStrings.ios_screenshots_ascreenshotalreadyinyour()
    /// S15
    static let keepsWhatsIn = AppStrings.ios_screenshots_whatsalreadyinyourjournal()
    /// S16
    static let pausedSubtext = AppStrings.ios_screenshots_youpausedthisscreenshotsyou()
    /// S17
    static let alreadyInJournal = AppStrings.ios_screenshots_screenshotsalreadyinyourjournal()
    /// S18
    static let lastCheckedLabel = AppStrings.ios_obsidian_lastchecked()
    /// S19
    static let waitingLabel = AppStrings.ios_obsidian_waitingtogotoyour()
    /// S21
    static let waitingForJournalUpdate = AppStrings.ios_screenshots_waitingforajournalupdate()
    /// I1
    static let whatItTakesIn = AppStrings.ios_screenshots_whilethisisonthe()
    /// I3
    static let turnOn = AppStrings.ios_screenshots_turnonscreenshots()
    /// I4
    static let turnOnHint = AppStrings.ios_screenshots_asksiosforaccessto()
    /// I5
    static let honestyLine = AppStrings.ios_screenshots_iosletsthesolstoneapp()
    /// I6
    static let limitedAtPrompt = AppStrings.ios_screenshots_iosissharingonlythe()
    /// I7
    static let limitedTile = AppStrings.ios_screenshots_photoaccessislimitedto()
    /// I8
    static let limitedPage = AppStrings.ios_screenshots_iosissharingonlythe2()
    /// I9
    static let accessOffTile = AppStrings.ios_screenshots_photoaccessisoff()
    /// I10
    static let accessOffPage = AppStrings.ios_screenshots_photoaccessisoffin()
    /// I11
    static let declined = AppStrings.ios_screenshots_thesolstoneappcantread()
    /// I12
    static let restricted = AppStrings.ios_screenshots_photosareturnedofffor()
    /// I13
    static let photosUsage = AppStrings.ios_screenshots_thesolstoneapptakesin()
    /// I14
    static let refusedType = AppStrings.ios_screenshots_thisscreenshotisina()
    /// I15
    static let tooBig = AppStrings.ios_screenshots_thisscreenshotistoobig()
    /// I16
    static let couldntCopy = AppStrings.ios_screenshots_thisscreenshotcouldntbecopied()
    /// I17
    static let couldntComeIn = AppStrings.ios_screenshots_thisscreenshotcouldntcomein()
    /// M3
    static let importLine = AppStrings.ios_screenshots_screenshotscomeinontheir()
    static let setUpScreenshots = AppStrings.ios_screenshots_setupscreenshots()
    static let openScreenshots = AppStrings.ios_screenshots_openscreenshots()
    static let tryAgain = AppStrings.ios_migration_offline_action()
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
        onPage ? AppStrings.ios_screenshots_ofscreenshotsinyourjournal_native("\(done)", "\(total)") : AppStrings.ios_screenshots_ofinyourjournal_native("\(done)", "\(total)")
    }

    /// S10. `start from today` for that choice, or a count of zero.
    static func confirmTitle(span: ScreenshotsSpan, count: Int) -> String {
        if span == .fromToday || count == 0 {
            return self.startFromToday
        }
        return AppStrings.ios_plural_screenshotsvocabulary_n96(count, "\(count)")
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
