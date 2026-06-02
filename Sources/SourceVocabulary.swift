// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceState: Equatable, Sendable {
    case off
    case enrolling
    case active
    case paused
    case needsAttention

    var label: String {
        switch self {
        case .off:
            "off"
        case .enrolling:
            "setting up"
        case .active:
            "on"
        case .paused:
            "paused"
        case .needsAttention:
            SourceVocabulary.needsAttention
        }
    }

    var symbol: String {
        switch self {
        case .off:
            "power.circle"
        case .enrolling:
            "arrow.triangle.2.circlepath"
        case .active:
            "checkmark.circle"
        case .paused:
            "pause.circle"
        case .needsAttention:
            "exclamationmark.triangle"
        }
    }

    var universalSubtext: String? {
        switch self {
        case .off:
            SourceVocabulary.offSubtext
        case .enrolling:
            SourceVocabulary.enrollingSubtext
        case .active:
            nil
        case .paused:
            SourceVocabulary.pausedSubtext
        case .needsAttention:
            SourceVocabulary.needsAttentionSubtext
        }
    }

    func subtext(activeSubtext: String) -> String {
        self.universalSubtext ?? activeSubtext
    }

    func voiceOverText(activeSubtext: String) -> String {
        switch self {
        case .off:
            "off. \(SourceVocabulary.offSubtext)"
        case .enrolling:
            "setting up. \(SourceVocabulary.enrollingSubtext)"
        case .active:
            "on. \(Self.sentence(activeSubtext))"
        case .paused:
            "paused. \(SourceVocabulary.pausedSubtext)"
        case .needsAttention:
            "\(SourceVocabulary.needsAttention). \(SourceVocabulary.needsAttentionSubtext)"
        }
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : "\(text)."
    }
}

nonisolated enum SourceVocabulary {
    static let offSubtext = "not sending to your journal. turn it on any time."
    static let enrollingSubtext = "getting ready — connecting to your journal."
    static let pausedSubtext = "you paused this. resume to start sending again."
    static let needsAttentionSubtext = "something's not getting through — tap to see what."
    static let needsAttention = "needs attention"

    static let observerActiveSubtext = "listening"
    static let importerActiveSubtext = "sending to your journal as you share."
    static let shareSheetDisplayName = "share sheet"
    static let shareSendingProgress = "sending to your journal…"
    static let shareDeliveredProgress = "in your journal"
    static let sendStateSaved = "saved on this phone"
    static let sendStateSending = "sending"

    static let experiencingAlongsideYouHeader = "experiencing alongside you"
    static let bringingInYourselfHeader = "bringing in yourself"
    static let trustLine = "feeds only your journal — nowhere else"

    static let recentEmpty = "nothing recent yet"
    static let recentFailed = "couldn't load recent"
    static let notConnectedRowAffordance = "connect your journal first"
    static let notConnectedDetailHelper = "connect your journal to turn this on."
    static let zeroActiveSummary = "nothing is on right now"
    static let whatItAdds = "adds what you say and nearby sound while this is on."
    static let pendingSeam = "nothing pending right now."
    static let removeSeam = "removing audio is coming later."
    static let importerWhatItAdds = "adds PDFs, audio, and images you send from the share sheet."
    static let onThisPhone = "on this phone"
    static let onThisPhoneScope = "shows things this phone saved from the share sheet and whether they reached your journal."
    static let onThisPhoneEmpty = "nothing here yet. things you send to your journal show up here so you can check they arrived."
    static let onThisPhoneFailed = "couldn't load what's on this phone"
    static let onThisPhoneSource = "source"
    static let onThisPhonePlacement = "placement"
    static let onThisPhoneDerived = "what sol made from it"
    static let failedImportSubtext = "this didn't reach your journal. you can retry or drop it."
    static let notProvided = "not provided"
    static let originAppNotProvided = "origin app not provided"
    static let rawOriginalUnavailable = "raw original is no longer on this phone."
    static let derivedNotInJournalYet = "not in your journal yet"
    static let derivedOpenInConvey = "open in convey ↗"
    static let openJournalInConvey = "open your journal in convey ↗"
    static let filenameLabel = "filename"
    static let originAppLabel = "origin app"
    static let sendStateLabel = "send state"
    static let deliveredAtLabel = "delivered at"
    static let retry = "retry"
    static let drop = "drop"
    static let turnOn = "turn on"
    static let pause = "pause"
    static let resume = "resume"
    static let delete = "delete"
    static let deleteConfirmBody = "delete everything share sheet added to your journal? this removes the originals you sent and what sol added from them. other things in your journal stay. this can't be undone."
    static let deleteConfirmButton = "delete share sheet's contributions"
    static let deleteReceiptHeadlineTemplate = "deleted. removed from your journal: {N} items you sent · the originals + a note of where each came from."
    static let deleteSourceOffLine = "share sheet is now off — turn it back on any time."
    static let deleteJournalUnreachableLine = "couldn't reach your journal — nothing was deleted."

    static func deleteReceiptHeadline(originals: Int) -> String {
        self.deleteReceiptHeadlineTemplate.replacingOccurrences(of: "{N}", with: String(originals))
    }
}
