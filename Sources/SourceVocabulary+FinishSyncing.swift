// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

extension SourceVocabulary {
    nonisolated static let finishSyncingCardHeadline = AppStrings.ios_app_finishsyncingcardheadline()

    nonisolated static func finishSyncingCardBody(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabularyfinishsyncing_n11(count, "\(count)")
    }

    nonisolated static let finishSyncingButton = AppStrings.ios_app_finishsyncingbutton()
    nonisolated static let finishSyncingInProgress = AppStrings.ios_app_finishsyncinginprogress()
    nonisolated static let finishSyncingCompleted = AppStrings.ios_app_finishsyncingcompleted()

    nonisolated static func finishSyncingInterrupted(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabularyfinishsyncing_n21(count, "\(count)")
    }

    nonisolated static let finishSyncingInterruptedFallback = AppStrings.ios_app_finishsyncinginterruptedfallback()
    nonisolated static let finishSyncingUnavailableUnavailable = AppStrings.ios_app_finishsyncingunavailableunavailable()
    nonisolated static let finishSyncingUnavailableNotPermitted = AppStrings.ios_app_finishsyncingunavailablenotpermitted()
    nonisolated static let finishSyncingUnavailableTooManyPending = AppStrings.ios_app_finishsyncingunavailabletoomanypending()
    nonisolated static let finishSyncingUnavailableImmediateIneligible = AppStrings.ios_app_finishsyncingunavailableimmediateineligible()
    nonisolated static let finishSyncingUnavailableFallback = AppStrings.ios_app_finishsyncingunavailablefallback()
    nonisolated static let finishSyncingSystemTitle = AppStrings.ios_app_finishsyncingsystemtitle()
    nonisolated static let finishSyncingSystemDoneTitle = AppStrings.ios_app_finishsyncingsystemdonetitle()
    nonisolated static let finishSyncingSystemPausedTitle = AppStrings.ios_app_finishsyncingsystempausedtitle()

    nonisolated static func finishSyncingSystemSubtitle(remaining: Int) -> String {
        AppStrings.ios_plural_sourcevocabularyfinishsyncing_n36(remaining, "\(remaining)")
    }

    nonisolated static func standingSyncFootnote(sustaining: Bool) -> String {
        sustaining
            ? AppStrings.ios_app_standingsyncfootnote_native()
            : AppStrings.ios_sourcevocabularyfinishsyncing_thesolstoneappsyncstoyourjournalwhileitsopena()
    }
}
