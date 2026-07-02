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
    static let needsAttentionSubtext = "something's not getting through."
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
    static let sendStateCompactSaved = "waiting to sync"
    static let sendStateCompactOnTheWay = "on the way"
    static let sendStateCompactInJournal = "in your journal"
    static let onThisPhoneWaitingExplain = "still on this phone. solstone keeps trying to sync it to your journal automatically — you don't have to do anything."
    static let tryNow = "try now"
    static let waitingToSync = sendStateCompactSaved
    static let screencastDisplayName = "screen"
    static let screencastActiveSubtext = "sharing your screen"
    static let screencastStartingSubtext = "waiting for the system sheet"
    static let screencastOffSubtext = "off"
    static let screencastAttentionSubtext = "needs attention"
    static let screencastUnavailableSubtext = "unavailable"
    static let screencastDetailTitle = "screen"
    static let screencastStateTitle = "state"
    static let screencastRecentTitle = "recent"
    static let screencastDeliveryTitle = "delivery"
    static let screencastStartButton = "start screen"
    static let screencastStopButton = "stop screen"
    static let screencastOpenSystemSheet = "open system sheet"
    static let screencastReadyText = "screen is ready"
    static let screencastStartingText = "waiting for the system sheet"
    static let screencastActiveText = "screen is active"
    static let screencastUnavailableText = "screen is unavailable"
    static let screencastNoVideoText = "no screen video was saved"
    static let screencastFinalizeFailedText = "screen video could not be saved"
    static let screencastPointerFailedText = "screen could not connect to this journal"

    static let experiencingAlongsideYouHeader = "experiencing alongside you"
    static let bringingInYourselfHeader = "bringing in yourself"
    static let trustLineUnpaired = "kept on this phone, only — nowhere else, until you connect a journal"
    static let trustLineConfigured = "syncs only to your journal — nowhere else"
    static let watchHeadlineOff = "off"
    static let watchHeadlineEnrolling = "setting up"
    static let watchHeadlineListening = "listening"
    static let watchHeadlinePaused = "paused"
    static let watchPipelineSending = "sending"
    static let watchPipelineSaved = "saved on your watch"
    static let watchPipelineUnknown = "—"
    static let watchPipelineHandedOff = "handed to your iphone"
    static let watchPipelineRelayStuckReason = "your watch has segments saved, but this iphone has not received anything for a while."
    static let watchPipelineHandoffStuckReason = "segments are on this iphone and waiting to reach your journal."
    static let watchPipelineOrphanStuckReason = "some segments stalled before they reached your journal."
    static let watchPipelineReportedGroupLabel = "reported by your watch"
    static let watchPipelineKnownGroupLabel = "known on this iphone"
    static let watchStuckNoticeTitle = "sync needs attention"
    static let watchPipelineRelayStuckNextStep = "keep your watch near this iphone. open solstone on your watch if this does not move."
    static let watchPipelineHandoffStuckNextStep = "keep solstone open here while your journal catches up."
    static let watchPipelineOrphanStuckNextStep = "open solstone on your watch and keep it near this iphone so it can send them again."
    static let watchWaitingForPhone = "waiting for your iphone"
    static let watchLinkConnected = "phone link: in range"
    static let watchLinkNotConnected = "phone link: out of range"
    static let watchNotSupported = "not available on this device"
    static let watchNoWatchPaired = "no watch paired with this iphone"
    static let watchAppNotInstalled = "solstone isn't on your watch yet"
    static let watchSourceDisplayName = "watch"
    static let watchNoContextSubtext = "haven't heard from your watch"
    static let watchConnectedNowSubtext = "your watch is connected right now"
    static let watchReceivingSubtext = "your watch is sending data"
    static let watchIdleSubtext = "no watch session right now — start solstone on your watch"
    static let watchListeningSubtext = "on your watch — listening"
    static let watchInstallTitle = "install solstone on your watch"
    static let watchInstallInstruction = "open the Watch app to install it"
    static let watchStateBlockTitle = "state"
    static let watchDeviceBlockTitle = "watch"
    static let watchDiagnosticsBlockTitle = "diagnostics"
    static let watchTechnicalDetailTitle = "technical detail"
    static let watchReceivedLabel = "received"
    static let watchNotYetInJournalLabel = "not yet in your journal"
    static let watchHandedToJournalLabel = "handed to your journal"
    static let watchLastSyncLabel = "last sync"
    static let watchLastSyncNever = "no sync yet"
    static let watchActivationLabel = "activation"
    static let watchPairedWithPhoneLabel = "paired with this iphone"
    static let watchInstalledLabel = "installed"
    static let watchLastReceivedLabel = "last received"
    static let watchLastReceivedNever = "nothing received yet"
    static let watchLastStagingDetailLabel = "last staging detail"
    static let watchLastLedgerDetailLabel = "last ledger detail"
    static let watchLastSyncDetailLabel = "last sync detail"
    static let watchLastUploadErrorLabel = "last upload error"
    static let watchStatusLabel = "watch status"
    static let watchReachableLabel = "reachable"
    static let watchDetailNone = "none"
    static let watchBooleanYes = "yes"
    static let watchBooleanNo = "no"
    static let watchActivationActivated = "activated"
    static let watchActivationInactive = "inactive"
    static let watchActivationNotActivated = "not activated"
    static let watchRelativeJustNow = "just now"
    static let watchShareDiagnosticsLabel = "share diagnostics"
    static let watchShareDiagnosticsHint = "shares watch diagnostics."
    static let watchPrepareDiagnosticsHint = "prepares watch diagnostics."
    static let watchDiagnosticsExportTitle = "watch diagnostics"
    static let watchDiagnosticsExportFileName = "watch-diagnostics.txt"

    static func trustLine(isPaired: Bool) -> String {
        isPaired ? Self.trustLineConfigured : Self.trustLineUnpaired
    }

    static func watchPipelineStaleAsOf(_ relative: String) -> String {
        "as of \(relative)"
    }

    static func watchSavedOnWatchCount(_ n: Int) -> String {
        "\(n) \(Self.watchPipelineSaved)"
    }

    static func watchSendingCount(_ n: Int) -> String {
        "\(n) \(Self.watchPipelineSending)"
    }

    static func watchHandedToPhoneCount(_ n: Int) -> String {
        "\(n) \(Self.watchPipelineHandedOff)"
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
    static let dayLocalityNoJournal = "no journal connected yet"
    static let journalConnected = "your journal · connected"
    static let journalOffline = "your journal · offline"
    static let dayToday = "today"
    static let yourSolstoneTitle = "your solstone"
    static let onThisPhoneScope = "everything your observers have gathered, resting here until you connect a journal."
    static let onThisPhoneScopeConnected = "everything your observers have gathered, moving into your journal."
    static let onThisPhoneScopeOfflinePaired = "everything your observers have gathered, ready for your journal when it reconnects."
    static let dayHomeAskBarHint = "connect a journal to ask sol"
    static let askBarOffline = "journal offline"
    static let askBarOfflineExplanationTitle = "sol needs your journal"
    static let askBarOfflineExplanationBody = "you're offline right now. sol answers from your journal — reconnect to your journal (on the same network, or wait for your connection to come back) and ask again. anything you gather stays safe on this phone until then."
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
    static let chatDeliveryWaitingConnection = "waiting for your journal…"
    static let chatDeliveryPosting = "sending to your journal…"
    static let chatDeliveryRetryingTransport = "couldn't reach your journal — retrying…"
    static let chatDeliveryRetryingUnavailable = "sol isn't available in your journal — retrying…"
    static func chatDeliveryBackpressure(queueDepth: Int?) -> String {
        if let queueDepth, queueDepth > 0 {
            return "your journal is busy — \(queueDepth) waiting, retrying…"
        }
        return "your journal is busy — retrying…"
    }
    static func chatDeliveryServerQueued(queueDepth: Int?) -> String {
        if let queueDepth, queueDepth > 0 {
            return "queued in your journal — \(queueDepth) waiting"
        }
        return "queued in your journal"
    }
    static let chatAnswerWaiting = "waiting for your journal's answer…"
    static let chatAnswerStreamReconnecting = "reconnecting to your journal's answer…"
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
    static let onThisPhoneEmpty = "nothing here yet. turn on a source and solstone starts experiencing alongside you — it'll wait here and sync to your journal once you connect one."
    static let onThisPhoneAllQuietHeadline = "all quiet"
    static let onThisPhoneAllQuietBody = "everything you've gathered is in your journal. new moments rest here on their way through."
    static let onThisPhoneNotBackedUp = "nothing here is backed up yet. connect a journal to keep a copy."
    static let onThisPhoneTurnOnSourceButton = "turn on a source"
    static let migrationStageOnThisPhone = "on this phone"
    static let migrationStageOnItsWay = "on its way"
    static let migrationStageInYourJournal = "in your journal"
    static let migrationHeadlineUpToDate = "your journal is up to date"
    static let syncingPulse = "syncing to your journal…"
    static let syncedHeadline = "all caught up"
    static let syncedBody = "everything's in your journal"
    static let offlineSafeLine = "safe here · your journal will catch up"
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
    static let journalTunnel = "private network"
    static let transferRateLabel = "transfer rate"
    static let transferRateIdle = "idle"
    static let lastSyncedLabel = "last synced"
    static let reconnectObserverButton = "reconnect this observer"
    static let reconnectObserverConfirmTitle = "reconnect this observer?"
    static let reconnectObserverConfirmBody = "this clears the stored observer key and registers fresh on next use."
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
    static let onThisPhoneWatchAudioSourceLabel = "watch audio"
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
    // VPX: functional placeholders pending product voice review.
    static let pairingLinked = "journal connected"
    static let pairingAlreadyConnected = "this journal is already connected"
    static let pairingReconnected = "journal connection updated"
    static let pairingReconnecting = "reconnecting…"
    static let journalMarkConfirmQuestion = "does this match your journal?"
    static let journalMarkConfirmSubtext = "your journal shows this same mark in its network app. it should match — exactly."
    static let journalMarkConfirmButton = "yes — this is my journal"
    static let journalMarkMismatchButton = "that doesn't match"
    static let journalMarkConfirmedLine = "this is your journal"
    static let journalMarkConnecting = "connecting…"
    static let journalMarkMismatchTitle = "not connected"
    static let journalMarkMismatchBody = "you said this mark doesn't match the one your journal shows — so we didn't connect this phone. you may have scanned the wrong code, or something isn't right. try again, or reach us and we'll help."
    static let journalMarkMismatchScanAgain = "scan again"
    static let journalMarkMismatchEmailSupport = "email support@solstone.app"
    static let rePairLine = "your journal asked this phone to reconnect."
    static let rePairAction = "re-pair"
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
    static let journalLivesRepairAction = "re-pair"

    static func journalLivesAction(isPaired: Bool) -> String {
        isPaired ? journalLivesRepairAction : journalLivesConnectAction
    }

    static func transferRateValue(bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB]
        return "~" + formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

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

    static func onThisPhoneDropSnackbar(descriptor: String) -> String {
        "dropped “\(descriptor)”."
    }

    static func onThisPhoneDropAudioDescriptor(duration: String) -> String {
        "\(duration) of audio"
    }

    static func onThisPhoneDropLocationDescriptor(count: Int) -> String {
        "\(count) observations"
    }

    static let onThisPhoneDropScreencastDescriptor = "screen video"

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
            ? "syncing 1 segment to your journal"
            : "syncing \(count) segments to your journal"
    }

    static func lastActiveLine(relative: String) -> String {
        "last active · \(relative)"
    }

    static func migrationStageCount(_ count: Int, stage: String) -> String {
        "\(count) \(stage)"
    }

    private static func onThisPhoneDatePhrase(relativeDay: String?, shortTime: String?) -> String? {
        guard let relativeDay else { return nil }
        guard let shortTime else { return relativeDay }
        return "\(relativeDay) at \(shortTime)"
    }
}

#if !os(watchOS)
extension SourceVocabulary {
    nonisolated static func onThisPhoneDropConfirmMessage(sendState: OnThisPhoneSendState) -> String {
        switch sendState {
        case .savedOnThisPhone, .sending, .needsAttention:
            return "this is only on your phone. dropping it means it won't reach your journal."
        case .inYourJournal:
            return "this is safely in your journal. dropping just clears it from this phone."
        }
    }

    nonisolated static func onThisPhoneSourceName(for sourceKind: OnThisPhoneSourceKind) -> String {
        switch sourceKind {
        case .audio:
            "audio"
        case .location:
            "location"
        case .screencast:
            "screen"
        case .share:
            Self.shareSheetDisplayName
        }
    }
}
#endif
