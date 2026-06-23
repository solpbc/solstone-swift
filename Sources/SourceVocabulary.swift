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
    static let modeExplanation = "Meeting keeps going until you stop it. Voice memo stops on its own when you go quiet for a few seconds."
    static let importerActiveSubtext = "sending to your journal as you share."
    static let shareAlwaysOnSubtext = "share to your journal from any app"
    static let shareAlwaysOnExplainer = "share is always on. anything you send from the share sheet comes into your journal here."
    static let shareSheetDisplayName = "share sheet"
    static let shareSendingProgress = "sending to your journal…"
    static let shareDeliveredProgress = "saved to your journal"
    static let sendStateSaved = "saved on this phone"
    static let sendStateSending = "sending"
    static let sendStateCompactSaved = "on this phone"
    static let sendStateCompactOnTheWay = "on the way"
    static let sendStateCompactInJournal = "in your journal"

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
    static let greetingMorning = "good morning"
    static let greetingAfternoon = "good afternoon"
    static let greetingEvening = "good evening"
    static let dayLocality = "your journal · on this phone"
    static let journalConnected = "your journal · connected"
    static let journalOffline = "your journal · offline"
    static let dayToday = "today"
    static let yourSolstoneTitle = "your solstone"
    static let onThisPhoneScope = "everything your observers have gathered, resting here until you connect a journal."
    static let onThisPhoneScopeConnected = "everything your observers have gathered, moving into your journal."
    static let onThisPhoneScopeOfflinePaired = "everything your observers have gathered, ready for your journal when it reconnects."
    static let dayHomeAskBarHint = "connect a journal to ask sol"
    static let askBarOffline = "journal offline"
    static let chatNavTitle = "ask sol"
    static let chatComposerPlaceholder = "ask sol…"
    static let chatEmptyHeading = "ask sol about your day"
    static let chatEmptyBody = "sol answers from your journal — and tells you where every answer comes from."
    static let chatEmptySeed1 = "what did i agree to this morning?"
    static let chatEmptySeed2 = "who did i talk to about the budget?"
    static let chatOfflineBanner = "your journal isn't reachable right now — i'll send your question the moment it's back."
    static let chatPendingStatusA11y = "waiting — will send automatically"
    static let chatFailedStatusA11y = "tap to retry"
    static let chatTypingA11y = "sol is thinking"
    static let chatSendA11y = "send"
    static let chatAckBubble = "i'm on it."
    static let chatFoldNotificationBody = "i have an answer for you."
    static let chatFoldAnchorTitle = "from your question"
    static let chatFoldInlineAskPrefix = "you asked"
    static let chatFoldOriginalQuestionUnavailable = "original question unavailable"
    static let chatTalentDetailTitle = "what sol is doing"
    static let chatTalentRunningTitle = "running"
    static let chatTalentQueuedTitle = "waiting"
    static let chatTalentQueuedFallback = "waiting to start"
    static let chatTalentTaskFallback = "working"
    static let chatTalentDetailEmpty = "nothing running right now"
    static let chatErrorEmptyReply = "sol returned an empty reply"
    static let chatErrorServer = "sol hit an error answering"
    static let chatErrorGeneric = "couldn't send"
    static let chatErrorDecode = "sol returned an invalid response"
    static let chatPartialHonestLine = "no source · i'd rather say i don't know than guess."
    static let chatAnswerFailedLine = "i couldn't finish that answer."
    static let chatRetryAnswer = "retry answer"
    static let chatOfferYes = "yes"
    static let chatOfferNo = "not now"
    static let chatSupportCapacityFrom = "sol"
    static let chatSupportCapacityTo = "solstone support"
    static let chatSupportCapacitySub = "nothing leaves without your ok."
    static let chatDraftReviewTitle = "review before sending"
    static let chatDraftConfirm = "send"
    static let chatDraftCancel = "cancel"
    static let chatDraftDiagnosticsIncluded = "diagnostics included"
    static let chatSourceOpenTitle = "open ↗"
    static let chatSourceSeparator = " · "
    static let onThisPhoneEmpty = "nothing here yet. turn on a source and solstone starts observing alongside you — kept right here."
    static let onThisPhoneNotBackedUp = "nothing here is backed up yet. connect a journal to keep a copy."
    static let onThisPhoneTurnOnSourceButton = "turn on a source"
    static let migrationStageOnThisPhone = "on this phone"
    static let migrationStageOnItsWay = "on its way"
    static let migrationStageInYourJournal = "in your journal"
    static let migrationHeadlineUpToDate = "your journal is up to date"
    static let magicMomentShownHeadline = "it's on your phone now"
    static let magicMomentShownBody = "sol just took in your first observation and kept it here — yours, and nowhere else."
    static let magicMomentShownSecondary = "connect a journal whenever →"
    static let magicMomentPendingHeadline = "your first audio observation is getting ready"
    static let magicMomentPendingBody = "when you stop listening, it will rest here on this phone."
    static let yourJournalSection = "your journal"
    static let details = "details"
    static let notProvided = "not provided"
    static let originAppNotProvided = "origin app not provided"
    static let rawOriginalUnavailable = "raw original is no longer on this phone."
    static let openJournalLink = "open journal ↗"
    static let openInJournal = "open in journal"
    static let journalTunnel = "journal tunnel"
    static let standingConnected = "connected"
    static let standingSyncing = "connected · syncing"
    static let standingOffline = "offline"
    static let standingDegraded = "connected · trouble reaching your journal"
    static let checkConnection = "check connection"
    static let probeReachable = "reachable"
    static let probeNotReachable = "not reachable"
    static let onThisPhoneJournalHintSaved = "sol added this to your journal automatically. open it to read the full thing."
    static let onThisPhoneJournalHintLocationSaved = "open it to see these places on a map."
    static let onThisPhoneJournalHintPending = "not in your journal yet — it'll appear once it's sent."
    static let onThisPhoneJournalHintUnreachable = "connect your journal first."
    static let onThisPhoneJournalHintLocationUnreachable = "connect your journal to see these places on a map."
    static let onThisPhoneDropFromPhone = "drop from this phone"
    static let onThisPhoneDropConfirmTitle = "drop this from this phone?"
    static let onThisPhoneFileLabel = "file"
    static let onThisPhoneWhenLabel = "when"
    static let onThisPhoneObservationsLabel = "observations"
    static let onThisPhoneSourceLabel = "source"
    static let onThisPhoneFailureReasonLabel = "why"
    static let onThisPhoneFailureStatusLabel = "status"
    static let onThisPhoneObserverAudioSourceLabel = "audio"
    static let onThisPhoneOmiAudioSourceLabel = "omi pendant audio"
    static let onThisPhoneFailureRowHint = "needs a retry"
    static let audioPlaybackObserverActiveHint = "pause listening to play this"
    static let audioPlaybackPlayLabel = "play audio"
    static let audioPlaybackPauseLabel = "pause audio"
    static let audioPlaybackHint = "plays this audio from this phone."
    static let connectJournalIntro = "your observations are kept on this phone. connect a journal and everything gathered so far flows in."
    static let connectDoorOwnTitle = "your own journal"
    static let connectDoorOwnSubtitle = "pair this phone to a solstone running on your computer."
    static let connectDoorHostedTitle = "a hosted journal"
    static let connectDoorHostedSubtitle = "a journal sol pbc keeps for you. on by you, off by you, yours either way."
    static let journalLivesTitle = "where your journal lives"
    static let journalLivesPromise = "your journal is always private, only yours."
    static let journalLivesOnThisPhoneTitle = "on this phone"
    static let journalLivesOnThisPhoneBody = "your observations rest here, yours and nowhere else."
    static let journalLivesOwnTitle = "your own journal"
    static let journalLivesOwnBody = "pair to a solstone on your computer — everything gathered so far flows in."
    static let journalLivesHostedTitle = "solstone hosted"
    static let journalLivesHostedBody = "a journal sol pbc keeps for you. operated by sol pbc."
    static let journalLivesComingLater = "coming later"
    static let journalLivesConnectAction = "connect"
    static let retry = "retry"
    static let drop = "drop"
    static let cancel = "cancel"
    static let undo = "undo"
    static let turnOn = "turn on"
    static let pause = "pause"
    static let resume = "resume"
    static let delete = "delete"
    static let deleteJournalUnreachableLine = "couldn't reach your journal — nothing was deleted."

    static func onThisPhoneAgedBacklog(count: Int) -> String {
        if count == 1 {
            return "1 observation is resting on this phone. connect a journal whenever you'd like a backup."
        }
        return "\(count) observations are resting on this phone. connect a journal whenever you'd like a backup."
    }

    static func chatSourceCount(_ n: Int) -> String {
        n == 1 ? "1 source" : "\(n) sources"
    }

    static func chatQueueCapacityLine(count: Int) -> String {
        count == 1 ? "1 message waiting for your journal" : "\(count) messages waiting for your journal"
    }

    static func chatSourcesPillA11yCollapsed(count: Int) -> String {
        let sourceCount = self.chatSourceCount(count)
        return "\(sourceCount), tap to view"
    }

    static func chatSourcesPillA11yExpanded(count: Int) -> String {
        let sourceCount = self.chatSourceCount(count)
        return "\(sourceCount), showing sources"
    }

    static func onThisPhoneLocationRowLabel(count: Int) -> String {
        count == 1 ? "1 observation" : "\(count) observations"
    }

    static func onThisPhoneDropConfirmMessage(sendState: OnThisPhoneSendState) -> String {
        switch sendState {
        case .savedOnThisPhone, .sending, .needsAttention:
            return "this is only on your phone. dropping it means it won't reach your journal."
        case .inYourJournal:
            return "this is safely in your journal. dropping just clears it from this phone."
        }
    }

    static func onThisPhoneDropSnackbar(descriptor: String) -> String {
        "dropped “\(descriptor)”."
    }

    static func onThisPhoneDropAudioDescriptor(duration: String) -> String {
        "\(duration) of audio"
    }

    static func onThisPhoneDropLocationDescriptor(count: Int) -> String {
        "\(count) observations"
    }

    static func onThisPhoneNavigationTitle(source: String, shortTime: String?) -> String {
        guard let shortTime else { return source }
        return "\(source) · \(shortTime)"
    }

    static func onThisPhoneAudioSummary(duration: String) -> String {
        "\(duration) of audio"
    }

    static func onThisPhoneLocationSummary(count: Int) -> String {
        count == 1 ? "1 observation" : "\(count) observations"
    }

    static func onThisPhoneObservedSummary(relativeDay: String?, shortTime: String?) -> String {
        guard let datePhrase = self.onThisPhoneDatePhrase(relativeDay: relativeDay, shortTime: shortTime) else {
            return "observed on this phone"
        }
        return "observed on this phone · \(datePhrase)"
    }

    static func onThisPhoneShareSummary(originApp: String?, relativeDay: String?, shortTime: String?) -> String {
        let origin = originApp.flatMap { $0.isEmpty ? nil : $0 }
        let datePhrase = self.onThisPhoneDatePhrase(relativeDay: relativeDay, shortTime: shortTime)
        switch (origin, datePhrase) {
        case (.some(let origin), .some(let datePhrase)):
            return "from \(origin) · \(datePhrase)"
        case (.some(let origin), .none):
            return "from \(origin)"
        case (.none, .some(let datePhrase)):
            return datePhrase
        case (.none, .none):
            return Self.notProvided
        }
    }

    static func onThisPhoneFileDetail(filename: String, size: String) -> String {
        "\(filename) · \(size)"
    }

    static func onThisPhoneFailureAttemptStatus(count: Int) -> String {
        count == 1 ? "upload failed after 1 attempt" : "upload failed after \(count) attempts"
    }

    static func onThisPhoneFailureRetryableMessage(count: Int) -> String {
        count == 1
            ? "hasn't reached your journal yet — tried 1 time. it'll try again automatically when you reconnect."
            : "hasn't reached your journal yet — tried \(count) times. it'll try again automatically when you reconnect."
    }

    static func onThisPhoneFailurePermanentMessage(reason: String) -> String {
        "this can't be sent — \(reason). you can remove it from this phone."
    }

    static let onThisPhoneFailureReasonNetwork = "the connection wasn't available"
    static let onThisPhoneFailureReasonTimeout = "the connection took too long"
    static let onThisPhoneFailureReasonServer = "your journal couldn't accept it"
    static let onThisPhoneFailureReasonUnknown = "something got in the way"

    static func onThisPhoneFailureLastTried(datePhrase: String) -> String {
        "last tried \(datePhrase)"
    }

    static func onThisPhoneFixCount(count: Int) -> String {
        count == 1 ? "1 fix" : "\(count) fixes"
    }

    static func migrationHeadlineSyncing(count: Int) -> String {
        count == 1
            ? "syncing 1 item to your journal"
            : "syncing \(count) items to your journal"
    }

    static func migrationHeadlineTrouble(count: Int) -> String {
        count == 1
            ? "1 waiting · trouble reaching your journal"
            : "\(count) waiting · trouble reaching your journal"
    }

    static func lastActiveLine(relative: String) -> String {
        "last active · \(relative)"
    }

    static func migrationStageCount(_ count: Int, stage: String) -> String {
        "\(count) \(stage)"
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

    private static func onThisPhoneDatePhrase(relativeDay: String?, shortTime: String?) -> String? {
        guard let relativeDay else { return nil }
        guard let shortTime else { return relativeDay }
        return "\(relativeDay) at \(shortTime)"
    }
}
