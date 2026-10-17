// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

extension SourceVocabulary {
    nonisolated static var finishSyncingCardHeadline: LocalizedStringResource { PilotCopy.finishSyncingCardHeadline }

    nonisolated static func finishSyncingCardBody(count: Int) -> SourceSyncMessage {
        PilotCopy.finishSyncingCardBody(count)
    }

    nonisolated static var finishSyncingButton: LocalizedStringResource { PilotCopy.finishSyncingButton }
    nonisolated static var finishSyncingInProgress: LocalizedStringResource { PilotCopy.finishSyncingInProgress }
    nonisolated static var finishSyncingCompleted: LocalizedStringResource { PilotCopy.finishSyncingCompleted }

    nonisolated static func finishSyncingInterrupted(count: Int) -> SourceSyncMessage {
        PilotCopy.finishSyncingInterrupted(count)
    }

    nonisolated static var finishSyncingInterruptedFallback: LocalizedStringResource { PilotCopy.finishSyncingInterruptedFallback }
    nonisolated static var finishSyncingUnavailableUnavailable: LocalizedStringResource { PilotCopy.finishSyncingUnavailableUnavailable }
    nonisolated static var finishSyncingUnavailableNotPermitted: LocalizedStringResource { PilotCopy.finishSyncingUnavailableNotPermitted }
    nonisolated static var finishSyncingUnavailableTooManyPending: LocalizedStringResource { PilotCopy.finishSyncingUnavailableTooManyPending }
    nonisolated static var finishSyncingUnavailableImmediateIneligible: LocalizedStringResource { PilotCopy.finishSyncingUnavailableImmediateIneligible }
    nonisolated static var finishSyncingUnavailableFallback: LocalizedStringResource { PilotCopy.finishSyncingUnavailableFallback }
    nonisolated static var finishSyncingSystemTitle: LocalizedStringResource { PilotCopy.finishSyncingSystemTitle }
    nonisolated static var finishSyncingSystemDoneTitle: LocalizedStringResource { PilotCopy.finishSyncingSystemDoneTitle }
    nonisolated static var finishSyncingSystemPausedTitle: LocalizedStringResource { PilotCopy.finishSyncingSystemPausedTitle }

    nonisolated static func finishSyncingSystemSubtitle(remaining: Int) -> SourceSyncMessage {
        PilotCopy.finishSyncingSystemSubtitle(remaining)
    }

    nonisolated static func standingSyncFootnote(sustaining: Bool) -> LocalizedStringResource {
        sustaining ? PilotCopy.standingSyncFootnoteSustaining : PilotCopy.standingSyncFootnoteLimited
    }
}
