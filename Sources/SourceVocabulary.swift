// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceState: Codable, Equatable, Sendable {
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
    private static let shareAlwaysOnExplainerUnpaired = "share is on. anything you send from another app is on this device until you connect a journal."
    private static let shareAlwaysOnExplainerPaired = "share is on. anything you send from the share sheet comes into your journal here."
    static let shareSheetDisplayName = "share sheet"
    static let shareSendingProgress = "sending to your journal…"
    static let shareDeliveredProgress = "saved to your journal"
    static let sendStateSaved = "on this device"
    static let sendStateSending = "sending"
    static let sendStateCompactSaved = "waiting to sync"
    static let sendStateCompactOnTheWay = "on the way"
    static let sendStateCompactInJournal = "in your journal"
    static let onThisPhoneWaitingExplain = "still on this device. syncing to your journal continues automatically. you don't have to do anything."
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

    static let addMoreTitle = "add more"
    static let addMoreSubline = "sources and devices"
    static let importTitle = "import"
    static let importSubline = "photos, files, anything"
    static let giveThisATileOnHome = "give this a tile on home"
    static let hidingThisNeverTurnsItOff = "hiding this never turns it off."
    static let whatItAddsTitle = "what it adds"
    static let openSettings = "open settings"
    static let trustLineConfigured = "syncs only to your journal"
    static let watchHeadlineOff = "off"
    static let watchHeadlineEnrolling = "setting up"
    static let watchHeadlineListening = "on"
    static let watchMicrophoneUnavailable = "microphone unavailable"
    static let watchAudioStoppedItself = "audio stopped itself"
    static let watchAudioCouldNotBeSaved = "audio could not be saved"
    static let watchStatusSaveFailed = "status could not be saved"
    static let watchStatusUnreadable = "status could not be read"
    static let watchManifestScanFailed = "saved items could not be checked"
    static let watchLocationUnavailable = "location unavailable"
    static let watchGenericUnavailable = "something went wrong"
    static let watchStatusAudioOutcomeLabel = "audio outcome"
    static let watchStatusAudioOutcomeOwnerStopped = "stopped by you"
    static let watchNoticeMicrophoneAccessTitle = "microphone access needed"
    static let watchNoticeMicrophoneAccessBody = "allow microphone access on your watch, then start again."
    static let watchNoticeAudioCouldNotStartTitle = "audio could not start"
    static let watchNoticeAudioCouldNotStartBody = "open the solstone app on your watch to start again."
    static let watchNoticeAudioStoppedTitle = "audio stopped itself"
    static let watchNoticeAudioStoppedBody = "open the solstone app on your watch to start again."
    static let watchNoticeAudioCouldNotBeSavedTitle = "audio could not be saved"
    static let watchNoticeAudioCouldNotBeSavedBody = "open the solstone app on your watch before your next moment."
    static let watchNoticeAudioCouldNotBeConfirmedTitle = "audio could not be confirmed"
    static let watchNoticeAudioCouldNotBeConfirmedBody = "open the solstone app on your watch to check audio."
    static let watchWristAlertWillTap = "you'll get a wrist tap if audio needs attention"
    static let watchWristAlertsOff = "wrist alerts are off"
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
    static let watchPipelineRelayStuckNextStep = "keep your watch near this iphone. open the solstone app on your watch if this does not move."
    static let watchPipelineHandoffStuckNextStep = "keep the solstone app open here while your journal catches up."
    static let watchPipelineOrphanStuckNextStep = "open the solstone app on your watch and keep it near this iphone so they can come over again."
    static let watchWaitingForPhone = "waiting for your iphone"
    static let watchLinkConnected = "phone link: in range"
    static let watchLinkNotConnected = "phone link: out of range"
    static let watchSourceDisplayName = "watch"
    static let watchComplicationUnknownHeadline = "the solstone app hasn't checked in"
    static let watchComplicationUnknownDetail = "open the solstone app on your watch"
    static let watchComplicationUnknownInline = "hasn't checked in"
    static let watchActivationFailedSubtext = "can't check your watch right now."
    static let watchNoWatchPairedSubtext = "no watch paired with this iphone."
    static let watchReadyToSetUpSubtext = "the solstone app can be on your watch. tap to set it up."
    static let watchInstalledNeverOpenedSubtext = "installed. now open the solstone app on your watch."
    static let watchReceivingNowSubtext = "receiving from your watch"
    static let watchIdleNowSubtext = "start the solstone app on your watch when you want it with you."
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
    static let watchSetupHeader = "the solstone app on your watch"
    static let watchSetupValueLine = "the solstone app on your watch takes in what you share from your wrist, hands it to this iphone, and it all syncs into your journal."
    static let watchSetupNoWatchBody = "pair an apple watch to this iphone and the solstone app can come along on your wrist. everything else in solstone works without one."
    static let watchCheckingLine = "checking your watch…"
    static let watchSetupInstallTitle = "install the solstone app from the Watch app"
    static let watchSetupInstallSubline = "in My Watch, scroll to Available Apps and tap install next to the solstone app."
    static let watchSetupInstallButton = "open the Watch app"
    static let watchSetupInstallButtonHint = "opens the Watch app."
    static let watchSetupInstallDisclosureSummary = "don't see the solstone app in the list?"
    static let watchSetupInstallDisclosureBody = "your watch may need watchOS 26 or newer. check Software Update in the Watch app. everything else in solstone works without a watch."
    static let watchSetupOpenTitle = "open the solstone app on your watch"
    static let watchSetupOpenSubline = "the solstone app checks in with this iphone the first time it opens."
    static let watchSetupFirstMomentTitle = "tap start for your first moment"
    static let watchSetupCelebration = "your watch's first memory just landed on this device."
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
    static let problemReportsToggleHint = "keeps app problem reports on this device so you can share them if you choose."
    static let problemReportsTitle = "problem reports"
    static let problemReportsRow = "problem reports"
    static let problemReportsRowHint = "opens problem reports kept on this device."
    static let problemReportsReportRowHint = "opens report detail."
    static let problemReportsOptedOutTitle = "problem reports are off"
    static let problemReportsOptedOutBody = "turn them on to keep reports on this device when the app quits or gets stuck."
    static let problemReportsEmptyTitle = "no problem reports yet"
    static let problemReportsEmptyBody = "reports will appear here if the solstone app quits unexpectedly or gets stuck."
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
    static let problemReportsDeleteAllConfirmBody = "this removes the reports kept on this device."
    static let problemReportsMissingTitle = "problem report unavailable"
    static let problemReportsMissingBody = "it may have already been deleted."

    static func watchPipelineStaleAsOf(_ relative: String) -> String {
        "as of \(relative)"
    }

    // L4.4 placeholders pending owner-facing copy signoff.
    static func watchStatusAsOf(_ relative: String) -> String {
        "watch status as of \(relative)"
    }
    static let watchStatusUnknownSubtext = "waiting for your watch to check in"
    static let watchStatusUnknownReason = "no status from your watch yet"

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
        "\(n) on your watch, waiting to come over. keep your watch nearby."
    }

    static func watchSteadyPhoneSyncingSentence(_ n: Int) -> String {
        "\(n) syncing to your journal…"
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
    private static let notConnectedRowAffordanceUnpaired = "connect a journal first."

    static func notConnectedRowAffordance(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.notConnectedRowAffordancePaired : Self.notConnectedRowAffordanceUnpaired
    }
    static let whatItAdds = "adds what you say and nearby sound while this is on."
    static let pendingSeam = "nothing pending right now."
    static let removeSeam = "removing audio is coming later."
    static let audioEnrollmentValue = "what you say and the sound around you, on this device until you connect a journal. turn it on only when you want to share audio."
    static let turnOnAudio = "turn on audio"
    static let importerWhatItAdds = "adds PDFs, audio, and images you send from the share sheet."
    static let onThisPhone = "on this device"
    static let greetingMorning = "good morning"
    static let greetingAfternoon = "good afternoon"
    static let greetingEvening = "good evening"
    static let dayLocalityNoJournal = "on this device · not paired"
    static let notPaired = "not paired"
    static let journalConnected = "your journal · connected"
    static let journalOffline = "your journal · offline"
    static let dayToday = "today"
    static let onThisPhoneScope = "everything you've shared, on this device until you connect a journal."
    static let onThisPhoneScopeConnected = "everything you've shared, moving into your journal."
    static let onThisPhoneScopeOfflinePaired = "everything you've shared, ready for your journal when it reconnects."
    static let onThisPhoneEmpty = "nothing here yet. turn on a source and the solstone app takes in what you share with it, and it goes into your journal."
    static let onThisPhoneTruthLine = "your memories are on this device and not processed until you connect a journal."
    static let onThisPhoneConnectJournalButton = "connect journal"
    static let onThisPhoneAllQuietHeadline = "all quiet"
    static let onThisPhoneAllQuietBody = "everything you've shared is in your journal. new moments rest here on their way through."
    static let onThisPhoneNotBackedUp = "nothing here is backed up yet. connect a journal to keep a copy."
    static let onThisPhoneTurnOnSourceButton = "turn on a source"
    static let migrationStageOnThisPhone = "on this device"
    static let migrationStageOnItsWay = "on its way"
    static let migrationStageInYourJournal = "in your journal"
    static let migrationHeadlineUpToDate = "your journal is up to date"
    static let syncingPulse = "syncing to your journal…"
    static let syncedHeadline = "all caught up"
    static let syncedBody = "everything is in your journal"
    static let offlineSafeLine = "on this device"
    static let magicMomentShownHeadline = "it's on this device now"
    static let magicMomentShownBody = "the solstone app just took in your first memory. it's on this device until you connect a journal."
    static let magicMomentShownSecondary = "connect a journal whenever →"
    static let magicMomentPendingHeadline = "your first audio memory is getting ready"
    static let magicMomentPendingBody = "when you stop, it will be on this device."
    static let yourJournalSection = "your journal"
    static let details = "details"
    static let notProvided = "not provided"
    static let originAppNotProvided = "origin app not provided"
    static let rawOriginalUnavailable = "the original is no longer on this device."
    static let openJournalLink = "open journal ↗"
    static let openInJournal = "open in journal"
    static let journalTunnel = "private network"
    static let transferRateLabel = "transfer rate"
    static let transferRateIdle = "idle"
    static let lastSyncedLabel = "last synced"
    static let reconnectObserverButton = "reconnect this device"
    static let reconnectObserverConfirmTitle = "reconnect this device?"
    static let reconnectObserverConfirmBody = "this clears the stored key and registers this device fresh on next use."
    static let checkConnection = "check connection"
    static let probeReachable = "reachable"
    static let probeNotReachable = "not reachable"
    static let onThisPhoneJournalHintSaved = "this was added to your journal automatically. open it to read the full thing."
    static let onThisPhoneJournalHintLocationSaved = "open it to see these places on a map."
    static let onThisPhoneJournalHintPending = "not in your journal yet — it'll appear once it's sent."
    static let onThisPhoneJournalHintUnreachable = "connect a journal first."
    static let onThisPhoneJournalHintLocationUnreachable = "connect a journal to see these places on a map."
    static let onThisPhoneDropFromPhone = "drop from this device"
    static let onThisPhoneDropConfirmTitle = "drop this from this device?"
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
    static let audioPlaybackHint = "plays this audio from this device."
    static let connectJournalIntro = "your memories are on this device. connect a journal and everything you've shared so far flows in."
    static let connectDoorOwnTitle = "your own journal"
    static let connectDoorOwnSubtitle = "pair this device to your journal running on your computer."
    static let connectDoorOnYourPhoneTitle = "on this device"
    static let connectDoorOnYourPhoneBody = "your journal as its own app, right on this device."
    static let connectJournalFloorLine = "no journal yet? that's fine. everything the solstone app takes in is on this device."
    static let connectJournalHowJournalsWork = "how journals work →"
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
    static let journalMarkMismatchBody = "you said this mark doesn't match the one your journal shows, so we didn't connect this device. you may have scanned the wrong code, or something isn't right. try again, or reach us and we'll help."
    static let journalMarkMismatchScanAgain = "scan again"
    static let journalMarkMismatchEmailSupport = "email support@solstone.app"
    static let rePairLine = "your journal asked this device to reconnect."
    static let rePairAction = "re-pair"
    static let journalLivesTitle = "where your journal lives"
    static let journalLivesPromise = "your journal is always private, only yours."
    static let journalLivesOwnTitle = "your own journal"
    static let journalLivesOwnBody = "pair to your journal on your computer. everything you've shared so far flows in."
    static let journalLivesOnYourPhoneTitle = "on this device"
    static let journalLivesOnYourPhoneBody = "your journal as its own app, right on this device."
    static let journalLivesCachedLine = "right now, just your memories are on this device, waiting to be processed."
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

    static func shareAlwaysOnExplainer(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.shareAlwaysOnExplainerPaired : Self.shareAlwaysOnExplainerUnpaired
    }

    static func onThisPhoneAgedBacklog(count: Int) -> String {
        if count == 1 {
            return "1 memory is on this device. connect a journal whenever you're ready."
        }
        return "\(count) memories are on this device. connect a journal whenever you're ready."
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
            return "on this device"
        }
        return "on this device · \(datePhrase)"
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
        "this can't go to your journal. \(reason). you can remove it from this device."
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

#if !os(watchOS) && !SOLSTONE_LIVE_ACTIVITY_WIDGET
extension SourceVocabulary {
    nonisolated static func onThisPhoneDropConfirmMessage(sendState: OnThisPhoneSendState) -> String {
        switch sendState {
        case .savedOnThisPhone, .sending, .needsAttention:
            return "this is only on this device. dropping it means it won't reach your journal."
        case .inYourJournal:
            return "this is in your journal. dropping just clears it from this device."
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
