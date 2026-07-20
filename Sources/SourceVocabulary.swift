// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceState: Equatable, Sendable {
    case off
    case enrolling
    case readyToSetUp
    case checking
    case active
    case paused
    case needsAttention

    var label: String {
        switch self {
        case .off:
            "off"
        case .enrolling:
            "setting up"
        case .readyToSetUp:
            SourceVocabulary.sourceStateReadyToSetUpLabel
        case .checking:
            SourceVocabulary.sourceStateCheckingLabel
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
        case .readyToSetUp:
            "plus.circle"
        case .checking:
            "arrow.triangle.2.circlepath"
        case .active:
            "checkmark.circle"
        case .paused:
            "pause.circle"
        case .needsAttention:
            "exclamationmark.triangle"
        }
    }

    func universalSubtext(isJournalPaired: Bool) -> String? {
        switch self {
        case .off:
            SourceVocabulary.offSubtext(isJournalPaired: isJournalPaired)
        case .enrolling:
            SourceVocabulary.enrollingSubtext(isJournalPaired: isJournalPaired)
        case .readyToSetUp, .checking:
            nil
        case .active:
            nil
        case .paused:
            SourceVocabulary.pausedSubtext
        case .needsAttention:
            SourceVocabulary.needsAttentionSubtext
        }
    }

    func subtext(activeSubtext: String, isJournalPaired: Bool) -> String {
        self.universalSubtext(isJournalPaired: isJournalPaired) ?? activeSubtext
    }

    func voiceOverText(activeSubtext: String, isJournalPaired: Bool) -> String {
        switch self {
        case .off:
            "off. \(SourceVocabulary.offSubtext(isJournalPaired: isJournalPaired))"
        case .enrolling:
            "setting up. \(SourceVocabulary.enrollingSubtext(isJournalPaired: isJournalPaired))"
        case .readyToSetUp:
            "\(SourceVocabulary.sourceStateReadyToSetUpLabel). \(Self.sentence(activeSubtext))"
        case .checking:
            "checking."
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
    private static let offSubtextUnpaired = "turn it on any time."
    private static let offSubtextPaired = "not sending to your journal. turn it on any time."
    private static let enrollingSubtextUnpaired = "getting ready…"
    private static let enrollingSubtextPaired = "getting ready — connecting to your journal."
    static let sourceStateReadyToSetUpLabel = "ready to set up"
    static let sourceStateCheckingLabel = "checking…"
    static let pausedSubtext = "you paused this. resume to start sending again."
    static let needsAttentionSubtext = "something's not getting through."
    static let needsAttention = "needs attention"

    static let observerActiveSubtext = "on"
    static let modeExplanation = "Meeting keeps going until you stop it. Voice memo stops on its own when you go quiet for a few seconds."
    private static let shareAlwaysOnSubtextUnpaired = "import from anywhere, it's saved here until you connect your journal."
    private static let shareAlwaysOnSubtextPaired = "share to your journal from any app"
    private static let shareAlwaysOnExplainerUnpaired = "share is always on. anything you send from another app is saved on this phone until you connect your journal."
    private static let shareAlwaysOnExplainerPaired = "share is always on. anything you send from the share sheet comes into your journal here."
    static let shareSheetDisplayName = "share sheet"
    static let shareSendingProgress = "sending to your journal…"
    static let shareDeliveredProgress = "saved to your journal"
    static let sendStateSaved = "saved on this phone"
    static let sendStateSending = "sending"
    static let sendStateCompactSaved = "waiting to sync"
    static let sendStateCompactOnTheWay = "on the way"
    static let sendStateCompactInJournal = "in your journal"
    static let onThisPhoneWaitingExplain = "still on this phone. sol keeps trying to sync it to your journal automatically — you don't have to do anything."
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

    static let experiencingAlongsideYouHeader = "experiencing your day with you"
    static let bringingInYourselfHeader = "import other memories"
    static let trustLineConfigured = "syncs only to your journal — nowhere else"
    static let watchHeadlineOff = "off"
    static let watchHeadlineEnrolling = "setting up"
    static let watchHeadlineListening = "on"
    static let watchHeadlinePaused = "paused"
    static let watchPipelineSending = "sending"
    static let watchPipelineSaved = "saved on your watch"
    static let watchPipelineUnknown = "—"
    static let watchPipelineConfirming = "confirming with your iphone"
    static let watchPipelineHandedOff = "handed to your iphone"
    static let watchPipelineRelayStuckReason = "your watch has segments saved, but this iphone has not received anything for a while."
    static let watchPipelineHandoffStuckReason = "segments are on this iphone and waiting to reach your journal."
    static let watchPipelineOrphanStuckReason = "some segments stalled before they reached your journal."
    static let watchPipelineReportedGroupLabel = "reported by your watch"
    static let watchPipelineKnownGroupLabel = "known on this iphone"
    static let watchStuckNoticeTitle = "sync needs attention"
    static let watchPipelineRelayStuckNextStep = "keep your watch near this iphone. open sol on your watch if this does not move."
    static let watchPipelineHandoffStuckNextStep = "keep sol open here while your journal catches up."
    static let watchPipelineOrphanStuckNextStep = "open sol on your watch and keep it near this iphone so it can send them again."
    static let watchWaitingForPhone = "waiting for your iphone"
    static let watchLinkConnected = "phone link: in range"
    static let watchLinkNotConnected = "phone link: out of range"
    static let watchSourceDisplayName = "watch"
    static let watchActivationFailedSubtext = "can't check your watch right now."
    static let watchNoWatchPairedSubtext = "no watch paired with this iphone."
    static let watchReadyToSetUpSubtext = "sol can be on your watch. tap to set it up."
    static let watchInstalledNeverOpenedSubtext = "installed. now open sol on your watch."
    static let watchReceivingNowSubtext = "receiving from your watch"
    static let watchIdleNowSubtext = "start sol on your watch when you want it with you."
    static let watchListeningSubtext = "on your watch, taking in audio"
    static let watchSteadyObservingHeadline = "on right now"
    static let watchObservingSentenceBase = "taking in audio on your watch"
    static let watchSteadyReceivingHeadline = "receiving now"
    static let watchSteadyWatchWaitingHeadline = "saved on your watch"
    static let watchSteadyPhoneSyncingHeadline = "on this iphone"
    static let watchSteadyCaughtUpSentence = "everything from your watch is in your journal."
    static let watchSteadyQuietHeadline = "quiet right now"
    static let watchPresenceConnectedNow = "your watch is connected right now"
    static let watchPresenceNeverHeard = "haven't heard from your watch yet"
    static let watchSetupHeader = "sol on your watch"
    static let watchSetupValueLine = "sol on your watch takes in audio and location from your wrist, hands it to this iphone, and it all syncs into your journal."
    static let watchSetupNoWatchBody = "pair an apple watch to this iphone and sol can come along on your wrist. everything else in solstone works without one."
    static let watchCheckingLine = "checking your watch…"
    static let watchSetupInstallTitle = "install sol from the Watch app"
    static let watchSetupInstallSubline = "in My Watch, scroll to Available Apps and tap install next to sol."
    static let watchSetupInstallButton = "open the Watch app"
    static let watchSetupInstallButtonHint = "opens the Watch app."
    static let watchSetupInstallDisclosureSummary = "don't see sol in the list?"
    static let watchSetupInstallDisclosureBody = "your watch may need watchos 26 or newer. check Software Update in the Watch app. everything else in solstone works without a watch."
    static let watchSetupOpenTitle = "open sol on your watch"
    static let watchSetupOpenSubline = "sol checks in with this iphone the first time it opens."
    static let watchSetupFirstMomentTitle = "tap start for your first moment"
    static let watchSetupCelebration = "your watch's first memory just landed on this phone."
    static let watchSetupStepPending = "pending"
    static let watchSetupStepActive = "active"
    static let watchSetupStepComplete = "complete"
    static let watchStateBlockTitle = "state"
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
    static let watchDiagnosticsStageReportEnvironment = "report + iphone environment"
    static let watchDiagnosticsStageWatchSnapshot = "latest watch snapshot"
    static let watchDiagnosticsStageRetentionAppleQueue = "watch retention + Apple queue"
    static let watchDiagnosticsStageIPhoneStaging = "iphone receipt + staging"
    static let watchDiagnosticsStageJournalHandoff = "journal handoff"
    static let watchDiagnosticsRelayAssessmentLabel = "relay assessment"
    static let watchDiagnosticsWatchUserInfoQueueLabel = "Watch → iPhone"
    static let watchDiagnosticsIPhoneACKQueueLabel = "iPhone → Watch durable ACK/control"
    static let watchDiagnosticsActiveBacklogLabel = "active backlog"
    static let watchDiagnosticsVisibleActiveLabel = "visible active"
    static let watchDiagnosticsOmittedActiveLabel = "omitted active"
    static let watchDiagnosticsEvidenceUnavailableLabel = "evidence unavailable"
    static let watchDiagnosticsOmittedObservationsLabel = "omitted observations"
    static let watchDiagnosticsPhoneLedgerLabel = "phone ledger"
    static let watchDiagnosticsPhoneLedgerRetainedEntriesLabel = "phone ledger retained entries"
    static let watchDiagnosticsPhoneLedgerReceivedLabel = "phone ledger received"
    static let watchDiagnosticsPhoneLedgerHandedLabel = "phone ledger handed"
    static let watchDiagnosticsPhoneLedgerDroppedLabel = "phone ledger dropped"
    static let watchDiagnosticsPhoneLedgerHandedAndDroppedLabel = "phone ledger handed + dropped"
    static let watchDiagnosticsIPhoneRecognizedACKLabel = "iPhone → Watch recognized ACK"
    static let watchDiagnosticsIPhoneParseableACKLabel = "iPhone → Watch parseable ACK"
    static let watchDiagnosticsIPhoneDistinctACKIdentitiesLabel = "iPhone → Watch distinct ACK identities"
    static let watchDiagnosticsIPhoneDuplicateACKExtrasLabel = "iPhone → Watch duplicate ACK extras"
    static let watchDiagnosticsIPhoneMalformedMissingACKLabel = "iPhone → Watch malformed/missing ACK"
    static let watchDiagnosticsIPhoneNonACKUserInfoLabel = "iPhone → Watch non-ACK user info"
    static let watchDiagnosticsVisibleActiveClassificationLabel = "visible active classification"
    static let watchDiagnosticsNotProvided = "not provided"
    static let watchDiagnosticsUnavailable = "unavailable"
    static let watchDiagnosticsIndeterminate = "indeterminate"
    static let problemReportsToggle = "keep problem reports"
    static let problemReportsToggleHint = "keeps app problem reports on this phone so you can share them if you choose."
    static let problemReportsTitle = "problem reports"
    static let problemReportsRow = "problem reports"
    static let problemReportsRowHint = "opens problem reports kept on this phone."
    static let problemReportsReportRowHint = "opens report detail."
    static let problemReportsOptedOutTitle = "problem reports are off"
    static let problemReportsOptedOutBody = "turn them on to keep reports on this phone when the app quits or gets stuck."
    static let problemReportsEmptyTitle = "no problem reports yet"
    static let problemReportsEmptyBody = "reports will appear here if sol quits unexpectedly or gets stuck."
    static let problemReportKindCrash = "app quit unexpectedly"
    static let problemReportKindHang = "app got stuck"
    static let problemReportKindCPUException = "app used too much processing time"
    static let problemReportKindDiskWriteException = "app wrote too much to storage"
    static let problemReportKindAppLaunch = "app took too long to open"
    static let problemReportKindAppExit = "app quit summary"
    static let problemReportKindUnknown = "app issue report"
    static let problemReportsShare = "share"
    static let problemReportsShareHint = "shares this problem report."
    static let problemReportsShareAll = "share all"
    static let problemReportsShareAllHint = "shares all problem reports."
    static let problemReportsDelete = "delete"
    static let problemReportsDeleteHint = "deletes this problem report."
    static let problemReportsDeleteAll = "delete all"
    static let problemReportsDeleteAllHint = "deletes all problem reports."
    static let problemReportsDeleteAllConfirmTitle = "delete all problem reports?"
    static let problemReportsDeleteAllConfirmBody = "this removes the reports kept on this phone."
    static let problemReportsMissingTitle = "problem report unavailable"
    static let problemReportsMissingBody = "it may have already been deleted."

    static func watchPipelineStaleAsOf(_ relative: String) -> String {
        "as of \(relative)"
    }

    static func watchSavedOnWatchCount(_ n: Int) -> String {
        "\(n) \(Self.watchPipelineSaved)"
    }

    static func watchSendingCount(_ n: Int) -> String {
        "\(n) \(Self.watchPipelineSending)"
    }

    static func watchConfirmingCount(_ n: Int) -> String {
        "\(n) \(Self.watchPipelineConfirming)"
    }

    static func watchHandedToPhoneCount(_ n: Int) -> String {
        "\(n) \(Self.watchPipelineHandedOff)"
    }

    static func watchWaitingToSyncFromWatch(_ n: Int) -> String {
        "\(n) waiting to sync from your watch"
    }

    static func watchObservingSentence(elapsedMinutes: Int?) -> String {
        guard let elapsedMinutes, elapsedMinutes >= 1 else {
            return Self.watchObservingSentenceBase
        }
        return "\(Self.watchObservingSentenceBase) · \(elapsedMinutes) min"
    }

    static func watchSteadyWatchWaitingSentence(_ n: Int) -> String {
        "\(n) waiting on your watch"
    }

    static func watchSteadyPhoneSyncingSentence(_ n: Int) -> String {
        "\(n) waiting to reach your journal"
    }

    static func watchPresenceLastHeard(relative: String) -> String {
        "last heard from your watch · \(relative)"
    }

    static func watchTodayHandedLine(_ n: Int) -> String {
        "today · handed \(n) to your journal"
    }

    static func watchSteadyDetailsSummary(watchWaiting: Int, phoneWaiting: Int) -> String {
        "details · watch \(watchWaiting) · iphone \(phoneWaiting) waiting"
    }

    static let recentEmpty = "nothing recent yet"
    static let recentFailed = "couldn't load recent"
    private static let notConnectedRowAffordancePaired = "opens when your journal reconnects."
    private static let notConnectedRowAffordanceUnpaired = "connect your journal first."

    static func notConnectedRowAffordance(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.notConnectedRowAffordancePaired : Self.notConnectedRowAffordanceUnpaired
    }
    static let whatItAdds = "adds what you say and nearby sound while this is on."
    static let pendingSeam = "nothing pending right now."
    static let removeSeam = "removing audio is coming later."
    static let audioEnrollmentValue = "what you say and the sound around you — kept on this phone, yours alone, until you connect a journal. turn it on only when you want sol with you."
    static let turnOnAudio = "turn on audio"
    static let importerWhatItAdds = "adds PDFs, audio, and images you send from the share sheet."
    static let onThisPhone = "on this phone"
    static let greetingMorning = "good morning"
    static let greetingAfternoon = "good afternoon"
    static let greetingEvening = "good evening"
    static let dayLocalityNoJournal = "on this phone · no journal yet"
    static let journalConnected = "your journal · connected"
    static let journalOffline = "your journal · offline"
    static let dayToday = "today"
    static let yourSolstoneTitle = "your journal"
    static let onThisPhoneScope = "everything sol has taken in, resting here until you connect a journal."
    static let onThisPhoneScopeConnected = "everything sol has taken in, moving into your journal."
    static let onThisPhoneScopeOfflinePaired = "everything sol has taken in, ready for your journal when it reconnects."
    static let dayHomeAskBarHint = "connect a journal to ask sol"
    static let askBarOffline = "journal offline"
    static let askBarOfflineExplanationTitle = "sol needs your journal"
    static let askBarOfflineExplanationBody = "you're offline right now. sol answers from your journal — reconnect to your journal (on the same network, or wait for your connection to come back) and ask again. anything you gather stays safe on this phone until then."
    static let chatNavTitle = "ask sol"
    static let chatComposerPlaceholder = "ask sol…"
    static let chatEmptyHeading = "ask sol about your day"
    static let chatEmptyBody = "sol answers from the memories in your journal."
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
    static let onThisPhoneEmpty = "nothing here yet. turn on a source and sol starts experiencing your day with you."
    static let onThisPhoneTruthLine = "your memories are saved only on this phone and not processed until you connect a journal."
    static let onThisPhoneConnectJournalButton = "connect journal"
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
    static let magicMomentShownBody = "sol just took in your first memory and kept it here — yours, and nowhere else."
    static let magicMomentShownSecondary = "connect a journal whenever →"
    static let magicMomentPendingHeadline = "your first audio memory is getting ready"
    static let magicMomentPendingBody = "when you stop, it will rest here on this phone."
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
    static let reconnectObserverButton = "reconnect this phone"
    static let reconnectObserverConfirmTitle = "reconnect this phone?"
    static let reconnectObserverConfirmBody = "this clears the stored key and registers this phone fresh on next use."
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
    static let onThisPhoneObservationsLabel = "memories"
    static let onThisPhoneSourceLabel = "source"
    static let onThisPhoneFailureReasonLabel = "why"
    static let onThisPhoneFailureStatusLabel = "status"
    static let onThisPhoneObserverAudioSourceLabel = "audio"
    static let onThisPhoneOmiAudioSourceLabel = "omi pendant audio"
    static let onThisPhoneWatchAudioSourceLabel = "watch audio"
    static let onThisPhoneFailureRowHint = "needs a retry"
    static let audioPlaybackObserverActiveHint = "pause to play this"
    static let audioPlaybackPlayLabel = "play audio"
    static let audioPlaybackPauseLabel = "pause audio"
    static let audioPlaybackHint = "plays this audio from this phone."
    static let connectJournalIntro = "your memories are cached on this phone. connect a journal and everything sol has taken in so far flows in."
    static let connectDoorOwnTitle = "your own journal"
    static let connectDoorOwnSubtitle = "pair this phone to your journal running on your computer."
    static let connectDoorOnYourPhoneTitle = "on your phone"
    static let connectDoorOnYourPhoneBody = "your journal as its own app, right on this phone."
    static let connectJournalFloorLine = "no journal yet? that's fine. everything sol takes in is saved safely on this phone."
    static let connectJournalHowJournalsWork = "how journals work →"
    static let askPreviewStateLine = "your day so far is resting on this phone. connect a journal so that sol can read it."
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
    static let journalLivesOwnTitle = "your own journal"
    static let journalLivesOwnBody = "pair to your journal on your computer. everything sol has taken in so far flows in."
    static let journalLivesOnYourPhoneTitle = "on your phone"
    static let journalLivesOnYourPhoneBody = "your journal as its own app, right on this phone."
    static let journalLivesCachedLine = "right now, just your cached memories are on this phone, waiting to be processed."
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

    static func offSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.offSubtextPaired : Self.offSubtextUnpaired
    }

    static func enrollingSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.enrollingSubtextPaired : Self.enrollingSubtextUnpaired
    }

    static func shareAlwaysOnSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.shareAlwaysOnSubtextPaired : Self.shareAlwaysOnSubtextUnpaired
    }

    static func shareAlwaysOnExplainer(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.shareAlwaysOnExplainerPaired : Self.shareAlwaysOnExplainerUnpaired
    }

    static func onThisPhoneAgedBacklog(count: Int) -> String {
        if count == 1 {
            return "1 memory is resting on this phone. connect a journal whenever you'd like a backup."
        }
        return "\(count) memories are resting on this phone. connect a journal whenever you'd like a backup."
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
        count == 1 ? "1 memory" : "\(count) memories"
    }

    static func onThisPhoneDropSnackbar(descriptor: String) -> String {
        "dropped “\(descriptor)”."
    }

    static func onThisPhoneDropAudioDescriptor(duration: String) -> String {
        "\(duration) of audio"
    }

    static func onThisPhoneDropLocationDescriptor(count: Int) -> String {
        "\(count) memories"
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
        count == 1 ? "1 memory" : "\(count) memories"
    }

    static func onThisPhoneObservedSummary(relativeDay: String?, shortTime: String?) -> String {
        guard let datePhrase = self.onThisPhoneDatePhrase(relativeDay: relativeDay, shortTime: shortTime) else {
            return "kept on this phone"
        }
        return "kept on this phone · \(datePhrase)"
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
