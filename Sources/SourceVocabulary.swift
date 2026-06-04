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
    static let shareDeliveredProgress = "saved to your journal"
    static let sendStateSaved = "saved on this phone"
    static let sendStateSending = "sending"

    static let experiencingAlongsideYouHeader = "experiencing alongside you"
    static let bringingInYourselfHeader = "bringing in yourself"
    static let trustLineUnpaired = "kept on this phone, only — nowhere else, until you connect a journal"
    static let trustLineConfigured = "feeds only your journal — nowhere else"

    static func trustLine(isPaired: Bool) -> String {
        isPaired ? Self.trustLineConfigured : Self.trustLineUnpaired
    }

    static let recentEmpty = "nothing recent yet"
    static let recentFailed = "couldn't load recent"
    static let notConnectedRowAffordance = "connect your journal first"
    static let sourcesConnectBanner = "kept here until you connect a journal · connect →"
    static let zeroActiveSummary = "nothing is on right now"
    static let whatItAdds = "adds what you say and nearby sound while this is on."
    static let pendingSeam = "nothing pending right now."
    static let removeSeam = "removing audio is coming later."
    static let audioEnrollmentValue = "what you say and the sound around you — kept on this phone, yours alone, until you connect a journal. turn it on only when you want solstone alongside you."
    static let turnOnAudio = "turn on audio"
    static let importerWhatItAdds = "adds PDFs, audio, and images you send from the share sheet."
    static let onThisPhone = "on this phone"
    static let onThisPhoneScope = "everything your observers have gathered, resting here until you connect a journal."
    static let onThisPhoneEmpty = "nothing here yet. turn on a source and solstone starts observing alongside you — kept right here."
    static let onThisPhoneDeleteReceipt = "deleted from this phone"
    static let onThisPhoneNotBackedUp = "on this phone only — not backed up. connect a journal to keep a copy."
    static let onThisPhoneSourceGapAccessibilityLabel = "couldn't read this source right now"
    static let magicMomentShownHeadline = "it's on your phone now"
    static let magicMomentShownBody = "sol just took in your first observation and kept it here — yours, and nowhere else."
    static let magicMomentShownSecondary = "connect a journal whenever →"
    static let magicMomentPendingHeadline = "your first audio observation is getting ready"
    static let magicMomentPendingBody = "when you stop listening, it will rest here on this phone."
    static let askEmptyHeadline = "nothing to ask yet"
    static let askEmptyBody = "sol answers from your journal. connect one, and sol can read everything your phone has gathered."
    static let askEmptyButton = "connect a journal"
    static let askEmptyIconName = "internaldrive"
    static let yourJournalSection = "your journal"
    static let onThisPhoneSource = "source"
    static let onThisPhonePlacement = "placement"
    static let failedImportSubtext = "this didn't reach your journal. you can retry or drop it."
    static let notProvided = "not provided"
    static let originAppNotProvided = "origin app not provided"
    static let rawOriginalUnavailable = "raw original is no longer on this phone."
    static let derivedNotInJournalYet = "not in your journal yet"
    static let openJournalInConvey = "open journal ↗"
    static let filenameLabel = "filename"
    static let originAppLabel = "origin app"
    static let sendStateLabel = "send state"
    static let deliveredAtLabel = "delivered at"
    static let connectJournalIntro = "your observations are kept on this phone. connect a journal and everything gathered so far flows in."
    static let connectDoorOwnTitle = "your own journal"
    static let connectDoorOwnSubtitle = "pair this phone to a solstone running on your computer."
    static let connectDoorHostedTitle = "a hosted journal"
    static let connectDoorHostedSubtitle = "a journal sol pbc keeps for you. on by you, off by you, yours either way."
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

    static func onThisPhoneAgedBacklog(count: Int) -> String {
        if count == 1 {
            return "1 observation is resting on this phone. connect a journal whenever you'd like a backup."
        }
        return "\(count) observations are resting on this phone. connect a journal whenever you'd like a backup."
    }

    static func askWaitingObservations(count: Int) -> String {
        if count == 1 {
            return "1 observation is waiting on this phone."
        }
        return "\(count) observations are waiting on this phone."
    }

    static func onThisPhoneLocationRowLabel(count: Int) -> String {
        count == 1 ? "1 observation" : "\(count) observations"
    }

    static func onThisPhoneSourceName(for sourceKind: OnThisPhoneSourceKind) -> String {
        switch sourceKind {
        case .audio:
            "audio"
        case .location:
            "location"
        case .share:
            Self.shareSheetDisplayName
        }
    }

    static func onThisPhoneCountNoun(for sourceKind: OnThisPhoneSourceKind, count: Int) -> String {
        switch sourceKind {
        case .audio:
            count == 1 ? "conversation" : "conversations"
        case .location:
            count == 1 ? "place" : "places"
        case .share:
            count == 1 ? "thing" : "things"
        }
    }

    static func onThisPhoneCountLabel(for sourceKind: OnThisPhoneSourceKind, count: Int?) -> String {
        guard let count else { return "—" }
        return "\(count) \(Self.onThisPhoneCountNoun(for: sourceKind, count: count))"
    }

    static func onThisPhoneCountAccessibilityLabel(for sourceKind: OnThisPhoneSourceKind, count: Int?) -> String {
        guard count != nil else { return Self.onThisPhoneSourceGapAccessibilityLabel }
        return Self.onThisPhoneCountLabel(for: sourceKind, count: count)
    }
}
