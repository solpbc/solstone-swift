// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner copy for the Photos Library source on iPhone.
/// Shared permission/control strings reuse `ScreenshotsVocabulary` and `SourceVocabulary`.
nonisolated enum PhotosVocabulary {
    static let label = AppStrings.ios_photos_label()
    static let tileSteady = AppStrings.ios_photos_tile_steady()
    static let tileScanning = AppStrings.ios_photos_tile_scanning()
    static let tileChoose = AppStrings.ios_photos_tile_choose()
    static let tilePaused = AppStrings.ios_photos_tile_paused()

    static let whatItTakesIn = AppStrings.ios_photos_page_whatittakesin()
    static let turnOn = AppStrings.ios_photos_action_turnon()
    static let turnOnHint = AppStrings.ios_photos_hint_turnon()
    static let alreadyGranted = AppStrings.ios_photos_page_alreadygranted()
    static let scanYourLibrary = AppStrings.ios_photos_action_scan()
    static let scanYourLibraryHint = AppStrings.ios_photos_hint_scan()
    static let scanningStarting = AppStrings.ios_photos_page_scanning_starting()
    static let scanFinished = AppStrings.ios_photos_page_scandone()
    static let chooseWhatComesIn = AppStrings.ios_photos_action_choose()
    static let steadyCanWiden = AppStrings.ios_photos_page_steady_widen()
    static let steadyAll = AppStrings.ios_photos_page_steady_all()
    static let openInJournal = AppStrings.ios_photos_action_openjournal()
    static let honestyLine = AppStrings.ios_photos_page_honesty()
    static let staysIfDeletedFromPhotos = AppStrings.ios_photos_fact_staysifdeleted()
    static let keepsWhatsIn = AppStrings.ios_photos_fact_keepswhatsin()

    static let unpairedReason = AppStrings.ios_photos_reason_unpaired()
    static let waitingForJournalUpdate = AppStrings.ios_photos_reason_journaltooold()
    static let limitedAtPrompt = AppStrings.ios_photos_reason_limitedprompt()
    static let declinedAtPrompt = AppStrings.ios_photos_reason_declined()
    static let restricted = ScreenshotsVocabulary.restricted
    static let limitedTile = ScreenshotsVocabulary.limitedTile
    static let limitedLater = AppStrings.ios_photos_reason_limitedlater()
    static let accessOffTile = ScreenshotsVocabulary.accessOffTile
    static let accessOffLater = AppStrings.ios_photos_reason_offlater()

    static func scanningProgress(checked: Int, total: Int, locale: Locale = .current) -> String {
        guard total > 0 else { return self.scanningStarting }
        return AppStrings.ios_photos_page_scanning_progress(
            SourceIntakeFormat.grouped(checked, locale: locale),
            SourceIntakeFormat.grouped(total, locale: locale)
        )
    }

    static func progress(done: Int, total: Int, onPage: Bool, locale: Locale = .current) -> String {
        let d = SourceIntakeFormat.grouped(done, locale: locale)
        let n = SourceIntakeFormat.grouped(total, locale: locale)
        return onPage
            ? AppStrings.ios_photos_page_progress(d, n)
            : AppStrings.ios_photos_tile_progress(d, n)
    }

    static func steadyLine(canWiden: Bool) -> String {
        canWiden ? self.steadyCanWiden : self.steadyAll
    }
}
