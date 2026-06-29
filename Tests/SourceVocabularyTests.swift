// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class SourceVocabularyTests: XCTestCase {
    func testLockedSourceStateLabels() {
        XCTAssertEqual(SourceState.off.label, "off")
        XCTAssertEqual(SourceState.enrolling.label, "setting up")
        XCTAssertEqual(SourceState.active.label, "on")
        XCTAssertEqual(SourceState.paused.label, "paused")
        XCTAssertEqual(SourceState.needsAttention.label, "needs attention")
    }

    func testJournalLivesActionReflectsPairingState() {
        XCTAssertEqual(SourceVocabulary.journalLivesAction(isPaired: false), "connect")
        XCTAssertEqual(SourceVocabulary.journalLivesAction(isPaired: true), "re-pair")
    }

    func testTransferRateValueFormatsApproximateThroughput() {
        let kbRate = SourceVocabulary.transferRateValue(bytesPerSecond: 240_000)
        XCTAssertTrue(kbRate.contains("~"), kbRate)
        XCTAssertTrue(kbRate.contains("KB/s"), kbRate)

        let mbRate = SourceVocabulary.transferRateValue(bytesPerSecond: 1_300_000)
        XCTAssertTrue(mbRate.contains("MB/s"), mbRate)
    }

    func testLockedOwnerSourceCopy() {
        XCTAssertEqual(
            SourceVocabulary.trustLineUnpaired,
            "kept on this phone, only — nowhere else, until you connect a journal"
        )
        XCTAssertEqual(SourceVocabulary.trustLineConfigured, "feeds only your journal — nowhere else")
        XCTAssertEqual(SourceVocabulary.trustLine(isPaired: false), SourceVocabulary.trustLineUnpaired)
        XCTAssertEqual(SourceVocabulary.trustLine(isPaired: true), SourceVocabulary.trustLineConfigured)
        XCTAssertEqual(SourceVocabulary.sourcesConnectBanner, "kept here until you connect a journal · connect →")
        XCTAssertEqual(SourceVocabulary.shareSendingProgress, "sending to your journal…")
        XCTAssertEqual(SourceVocabulary.shareDeliveredProgress, "saved to your journal")
        XCTAssertEqual(SourceVocabulary.shareAlwaysOnSubtext, "share to your journal from any app")
        XCTAssertEqual(
            SourceVocabulary.shareAlwaysOnExplainer,
            "share is always on. anything you send from the share sheet comes into your journal here."
        )
        XCTAssertEqual(SourceVocabulary.sendStateCompactSaved, "on this phone")
        XCTAssertEqual(SourceVocabulary.sendStateCompactOnTheWay, "on the way")
        XCTAssertEqual(SourceVocabulary.sendStateCompactInJournal, "in your journal")
        XCTAssertEqual(
            SourceVocabulary.audioEnrollmentValue,
            "what you say and the sound around you — kept on this phone, yours alone, until you connect a journal. turn it on only when you want solstone alongside you."
        )
        XCTAssertEqual(SourceVocabulary.turnOnAudio, "turn on audio")
        XCTAssertEqual(SourceVocabulary.onThisPhone, "on this phone")
        XCTAssertEqual(SourceVocabulary.yourJournalSection, "your journal")
        XCTAssertEqual(SourceVocabulary.transferRateLabel, "transfer rate")
        XCTAssertEqual(SourceVocabulary.transferRateIdle, "idle")
        XCTAssertEqual(SourceVocabulary.details, "details")
        XCTAssertEqual(SourceVocabulary.dayHomeAskBarHint, "connect a journal to ask sol")
        XCTAssertEqual(SourceVocabulary.dayLocalityNoJournal, "no journal connected yet")
        XCTAssertEqual(SourceVocabulary.journalConnected, "your journal · connected")
        XCTAssertEqual(SourceVocabulary.journalOffline, "your journal · offline")
        XCTAssertEqual(SourceVocabulary.yourSolstoneTitle, "your solstone")
        XCTAssertEqual(SourceVocabulary.openInJournal, "open in journal")
        XCTAssertEqual(SourceVocabulary.askBarOffline, "journal offline")
        XCTAssertEqual(SourceVocabulary.askBarOfflineExplanationTitle, "sol needs your journal")
        XCTAssertEqual(
            SourceVocabulary.askBarOfflineExplanationBody,
            "you're offline right now. sol answers from your journal — reconnect to your journal (on the same network, or wait for your connection to come back) and ask again. anything you gather stays safe on this phone until then."
        )
        XCTAssertEqual(SourceVocabulary.chatNavTitle, "ask sol")
        XCTAssertEqual(SourceVocabulary.chatComposerPlaceholder, "ask sol…")
        XCTAssertEqual(SourceVocabulary.chatEmptyHeading, "ask sol about your day")
        XCTAssertEqual(
            SourceVocabulary.chatEmptyBody,
            "sol answers from your journal — and tells you where every answer comes from."
        )
        XCTAssertEqual(SourceVocabulary.chatEmptySeed1, "what did i agree to this morning?")
        XCTAssertEqual(SourceVocabulary.chatEmptySeed2, "who did i talk to about the budget?")
        XCTAssertEqual(
            SourceVocabulary.chatOfflineBanner,
            "your journal isn't reachable right now — i'll send your question the moment it's back."
        )
        XCTAssertEqual(SourceVocabulary.chatPendingStatusA11y, "waiting — will send automatically")
        XCTAssertEqual(SourceVocabulary.chatFailedStatusA11y, "tap to retry")
        XCTAssertEqual(SourceVocabulary.chatTypingA11y, "sol is thinking")
        XCTAssertEqual(SourceVocabulary.chatSendA11y, "send")
        XCTAssertEqual(SourceVocabulary.chatAckBubble, "i'm on it.")
        XCTAssertEqual(SourceVocabulary.chatFoldNotificationBody, "i have an answer for you.")
        XCTAssertEqual(SourceVocabulary.chatFoldAnchorTitle, "from your question")
        XCTAssertEqual(SourceVocabulary.chatFoldInlineAskPrefix, "you asked")
        XCTAssertEqual(SourceVocabulary.chatFoldOriginalQuestionUnavailable, "original question unavailable")
        XCTAssertEqual(SourceVocabulary.chatTalentDetailTitle, "what sol is doing")
        XCTAssertEqual(SourceVocabulary.chatTalentRunningTitle, "running")
        XCTAssertEqual(SourceVocabulary.chatTalentQueuedTitle, "waiting")
        XCTAssertEqual(SourceVocabulary.chatTalentQueuedFallback, "waiting to start")
        XCTAssertEqual(SourceVocabulary.chatTalentTaskFallback, "working")
        XCTAssertEqual(SourceVocabulary.chatTalentDetailEmpty, "nothing running right now")
        XCTAssertEqual(SourceVocabulary.chatErrorEmptyReply, "sol returned an empty reply")
        XCTAssertEqual(SourceVocabulary.chatErrorServer, "sol hit an error answering")
        XCTAssertEqual(SourceVocabulary.chatErrorGeneric, "couldn't send")
        XCTAssertEqual(SourceVocabulary.chatErrorDecode, "sol returned an invalid response")
        XCTAssertEqual(SourceVocabulary.chatPartialHonestLine, "no source · i'd rather say i don't know than guess.")
        XCTAssertEqual(SourceVocabulary.chatAnswerFailedLine, "i couldn't finish that answer.")
        XCTAssertEqual(SourceVocabulary.chatRetryAnswer, "retry answer")
        XCTAssertEqual(SourceVocabulary.chatOfferYes, "yes")
        XCTAssertEqual(SourceVocabulary.chatOfferNo, "not now")
        XCTAssertEqual(SourceVocabulary.chatSupportCapacityFrom, "sol")
        XCTAssertEqual(SourceVocabulary.chatSupportCapacityTo, "solstone support")
        XCTAssertEqual(SourceVocabulary.chatSupportCapacitySub, "nothing leaves without your ok.")
        XCTAssertEqual(SourceVocabulary.chatDraftReviewTitle, "review before sending")
        XCTAssertEqual(SourceVocabulary.chatDraftConfirm, "send")
        XCTAssertEqual(SourceVocabulary.chatDraftCancel, "cancel")
        XCTAssertEqual(SourceVocabulary.chatDraftDiagnosticsIncluded, "diagnostics included")
        XCTAssertEqual(SourceVocabulary.chatSourceOpenTitle, "open ↗")
        XCTAssertEqual(SourceVocabulary.chatSourceSeparator, " · ")
        XCTAssertEqual(SourceVocabulary.chatSourceCount(1), "1 source")
        XCTAssertEqual(SourceVocabulary.chatSourceCount(2), "2 sources")
        XCTAssertEqual(SourceVocabulary.chatQueueCapacityLine(count: 1), "1 message waiting for your journal")
        XCTAssertEqual(SourceVocabulary.chatQueueCapacityLine(count: 3), "3 messages waiting for your journal")
        XCTAssertEqual(
            SourceVocabulary.chatSourcesPillA11yCollapsed(count: 2),
            "2 sources, tap to view"
        )
        XCTAssertEqual(
            SourceVocabulary.chatSourcesPillA11yExpanded(count: 1),
            "1 source, showing sources"
        )
        XCTAssertEqual(
            SourceVocabulary.connectJournalIntro,
            "your observations are kept on this phone. connect a journal and everything gathered so far flows in."
        )
        XCTAssertEqual(SourceVocabulary.connectDoorOwnTitle, "your own journal")
        XCTAssertEqual(SourceVocabulary.connectDoorOwnSubtitle, "pair this phone to a solstone running on your computer.")
        XCTAssertEqual(SourceVocabulary.connectDoorHostedTitle, "a hosted journal")
        XCTAssertEqual(
            SourceVocabulary.connectDoorHostedSubtitle,
            "a journal sol pbc keeps for you. on by you, off by you, yours either way."
        )
        XCTAssertEqual(SourceVocabulary.pairingLinked, "journal connected")
        XCTAssertEqual(SourceVocabulary.pairingAlreadyConnected, "this journal is already connected")
        XCTAssertEqual(SourceVocabulary.pairingReconnected, "journal connection updated")
        XCTAssertEqual(SourceVocabulary.pairingReconnecting, "reconnecting…")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneScope,
            "everything your observers have gathered, resting here until you connect a journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneScopeConnected,
            "everything your observers have gathered, moving into your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneScopeOfflinePaired,
            "everything your observers have gathered, ready for your journal when it reconnects."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneEmpty,
            "nothing here yet. turn on a source and solstone starts experiencing alongside you — it'll wait here and sync to your journal once you connect one."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneAllQuietHeadline, "all quiet")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAllQuietBody,
            "everything you've gathered is in your journal. new moments rest here on their way through."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneNotBackedUp,
            "nothing here is backed up yet. connect a journal to keep a copy."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneTurnOnSourceButton, "turn on a source")
        XCTAssertEqual(SourceVocabulary.migrationStageOnThisPhone, "on this phone")
        XCTAssertEqual(SourceVocabulary.migrationStageOnItsWay, "on its way")
        XCTAssertEqual(SourceVocabulary.migrationStageInYourJournal, "in your journal")
        XCTAssertEqual(SourceVocabulary.migrationHeadlineUpToDate, "your journal is up to date")
        XCTAssertEqual(SourceVocabulary.syncingPulse, "syncing to your journal…")
        XCTAssertEqual(SourceVocabulary.syncedHeadline, "all caught up")
        XCTAssertEqual(SourceVocabulary.syncedBody, "everything's in your journal")
        XCTAssertEqual(SourceVocabulary.offlineSafeLine, "safe here · your journal will catch up")
        XCTAssertEqual(SourceVocabulary.needsAttentionRow(count: 1), "1 needs attention")
        XCTAssertEqual(SourceVocabulary.needsAttentionRow(count: 3), "3 need attention")
        XCTAssertEqual(SourceVocabulary.migrationHeadlineSyncing(count: 1), "syncing 1 segment to your journal")
        XCTAssertEqual(SourceVocabulary.migrationHeadlineSyncing(count: 2), "syncing 2 segments to your journal")
        XCTAssertEqual(SourceVocabulary.lastActiveLine(relative: "just now"), "last active · just now")
        XCTAssertEqual(
            SourceVocabulary.migrationStageCount(12, stage: SourceVocabulary.migrationStageOnItsWay),
            "12 on its way"
        )
        XCTAssertEqual(SourceVocabulary.magicMomentShownHeadline, "it's on your phone now")
        XCTAssertEqual(
            SourceVocabulary.magicMomentShownBody,
            "sol just took in your first observation and kept it here — yours, and nowhere else."
        )
        XCTAssertEqual(SourceVocabulary.magicMomentShownSecondary, "connect a journal whenever →")
        XCTAssertEqual(SourceVocabulary.magicMomentPendingHeadline, "your first audio observation is getting ready")
        XCTAssertEqual(SourceVocabulary.magicMomentPendingBody, "when you stop listening, it will rest here on this phone.")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAgedBacklog(count: 1),
            "1 observation is resting on this phone. connect a journal whenever you'd like a backup."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAgedBacklog(count: 12),
            "12 observations are resting on this phone. connect a journal whenever you'd like a backup."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationRowLabel(count: 1), "1 observation")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationRowLabel(count: 12), "12 observations")
        XCTAssertEqual(SourceVocabulary.openJournalLink, "open journal ↗")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneJournalHintSaved,
            "sol added this to your journal automatically. open it to read the full thing."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneJournalHintLocationSaved, "open it to see these places on a map.")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneJournalHintPending,
            "not in your journal yet — it'll appear once it's sent."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneJournalHintUnreachable, "connect your journal first.")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneJournalHintLocationUnreachable,
            "connect your journal to see these places on a map."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropFromPhone, "drop from this phone")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropConfirmTitle, "drop this from this phone?")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .savedOnThisPhone),
            "this is only on your phone. dropping it means it won't reach your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .sending),
            "this is only on your phone. dropping it means it won't reach your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .needsAttention),
            "this is only on your phone. dropping it means it won't reach your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .inYourJournal),
            "this is safely in your journal. dropping just clears it from this phone."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropSnackbar(descriptor: "1m 15s of audio"), "dropped “1m 15s of audio”.")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropAudioDescriptor(duration: "1m 15s"), "1m 15s of audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropLocationDescriptor(count: 2), "2 observations")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFileLabel, "file")
        XCTAssertEqual(SourceVocabulary.onThisPhoneWhenLabel, "when")
        XCTAssertEqual(SourceVocabulary.onThisPhoneObservationsLabel, "observations")
        XCTAssertEqual(SourceVocabulary.onThisPhoneSourceLabel, "source")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonLabel, "why")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureStatusLabel, "status")
        XCTAssertEqual(SourceVocabulary.onThisPhoneObserverAudioSourceLabel, "audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneOmiAudioSourceLabel, "omi pendant audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneWatchAudioSourceLabel, "watch audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureRowHint, "needs a retry")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureAttemptStatus(count: 1), "upload failed after 1 attempt")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureAttemptStatus(count: 5), "upload failed after 5 attempts")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneFailureRetryableMessage(count: 1),
            "hasn't reached your journal yet — tried 1 time. it'll try again automatically when you reconnect."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneFailureRetryableMessage(count: 5),
            "hasn't reached your journal yet — tried 5 times. it'll try again automatically when you reconnect."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneFailurePermanentMessage(reason: "the connection wasn't available"),
            "this can't be sent — the connection wasn't available. you can remove it from this phone."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonNetwork, "the connection wasn't available")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonTimeout, "the connection took too long")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonServer, "your journal couldn't accept it")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonUnknown, "something got in the way")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneFailureLastTried(datePhrase: "today at 3:00 PM"),
            "last tried today at 3:00 PM"
        )
        XCTAssertEqual(SourceVocabulary.audioPlaybackObserverActiveHint, "pause listening to play this")
        XCTAssertEqual(SourceVocabulary.audioPlaybackPlayLabel, "play audio")
        XCTAssertEqual(SourceVocabulary.audioPlaybackPauseLabel, "pause audio")
        XCTAssertEqual(SourceVocabulary.audioPlaybackHint, "plays this audio from this phone.")
        XCTAssertEqual(SourceVocabulary.onThisPhoneNavigationTitle(source: "audio", shortTime: nil), "audio")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneNavigationTitle(source: "audio", shortTime: "9:30 AM"),
            "audio · 9:30 AM"
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneAudioSummary(duration: "1m 15s"), "1m 15s of audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationSummary(count: 1), "1 observation")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationSummary(count: 3), "3 observations")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneObservedSummary(relativeDay: "today", shortTime: "9:30 AM"),
            "observed on this phone · today at 9:30 AM"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneObservedSummary(relativeDay: "today", shortTime: nil),
            "observed on this phone · today"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneObservedSummary(relativeDay: nil, shortTime: nil),
            "observed on this phone"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneShareSummary(originApp: "Files", relativeDay: "today", shortTime: "9:30 AM"),
            "from Files · today at 9:30 AM"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneShareSummary(originApp: nil, relativeDay: "today", shortTime: "9:30 AM"),
            "today at 9:30 AM"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneShareSummary(originApp: "Files", relativeDay: nil, shortTime: nil),
            "from Files"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneShareSummary(originApp: nil, relativeDay: nil, shortTime: nil),
            SourceVocabulary.notProvided
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneFileDetail(filename: "item.pdf", size: "2 KB"),
            "item.pdf · 2 KB"
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneFixCount(count: 1), "1 fix")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFixCount(count: 3), "3 fixes")
        XCTAssertEqual(SourceVocabulary.cancel, "cancel")
        XCTAssertEqual(SourceVocabulary.undo, "undo")
        XCTAssertEqual(SourceVocabulary.needsAttention, "needs attention")
        XCTAssertEqual(SourceVocabulary.journalTunnel, "private network")
        XCTAssertEqual(SourceVocabulary.standingConnected, "connected")
        XCTAssertEqual(SourceVocabulary.standingSyncing, "connected · syncing")
        XCTAssertEqual(SourceVocabulary.standingOffline, "offline")
        XCTAssertEqual(SourceVocabulary.standingDegraded, "connected · trouble reaching your journal")
        XCTAssertEqual(SourceVocabulary.checkConnection, "check connection")
        XCTAssertEqual(SourceVocabulary.probeReachable, "reachable")
        XCTAssertEqual(SourceVocabulary.probeNotReachable, "not reachable")
        XCTAssertEqual(SourceVocabulary.watchNotSupported, "not available on this device")
        XCTAssertEqual(SourceVocabulary.watchNoWatchPaired, "no watch paired with this iphone")
        XCTAssertEqual(SourceVocabulary.watchAppNotInstalled, "solstone isn't on your watch yet")
        XCTAssertEqual(SourceVocabulary.watchSourceDisplayName, "watch")
        XCTAssertEqual(SourceVocabulary.watchLinkConnected, "phone link: in range")
        XCTAssertEqual(SourceVocabulary.watchLinkNotConnected, "phone link: out of range")
        XCTAssertEqual(SourceVocabulary.watchNoContextSubtext, "haven't heard from your watch")
        XCTAssertEqual(SourceVocabulary.watchIdleSubtext, "no watch session right now — start solstone on your watch")
        XCTAssertEqual(SourceVocabulary.watchListeningSubtext, "on your watch — listening")
        XCTAssertEqual(SourceVocabulary.watchInstallTitle, "install solstone on your watch")
        XCTAssertEqual(SourceVocabulary.watchInstallInstruction, "open the Watch app to install it")
        XCTAssertEqual(SourceVocabulary.watchStateBlockTitle, "state")
        XCTAssertEqual(SourceVocabulary.watchDeviceBlockTitle, "watch")
        XCTAssertEqual(SourceVocabulary.watchDiagnosticsBlockTitle, "diagnostics")
        XCTAssertEqual(SourceVocabulary.watchTechnicalDetailTitle, "technical detail")
        XCTAssertEqual(SourceVocabulary.watchReceivedLabel, "received")
        XCTAssertEqual(SourceVocabulary.watchWaitingLabel, "waiting")
        XCTAssertEqual(SourceVocabulary.watchHandedToJournalLabel, "handed to your journal")
        XCTAssertEqual(SourceVocabulary.watchLastSyncLabel, "last sync")
        XCTAssertEqual(SourceVocabulary.watchLastSyncNever, "no sync yet")
        XCTAssertEqual(SourceVocabulary.watchActivationLabel, "activation")
        XCTAssertEqual(SourceVocabulary.watchPairedWithPhoneLabel, "paired with this iphone")
        XCTAssertEqual(SourceVocabulary.watchInstalledLabel, "installed")
        XCTAssertEqual(SourceVocabulary.watchLastReceivedLabel, "last received")
        XCTAssertEqual(SourceVocabulary.watchLastReceivedNever, "nothing received yet")
        XCTAssertEqual(SourceVocabulary.watchLastStagingDetailLabel, "last staging detail")
        XCTAssertEqual(SourceVocabulary.watchLastSyncDetailLabel, "last sync detail")
        XCTAssertEqual(SourceVocabulary.watchLastUploadErrorLabel, "last upload error")
        XCTAssertEqual(SourceVocabulary.watchStatusLabel, "watch status")
        XCTAssertEqual(SourceVocabulary.watchDetailNone, "none")
        XCTAssertEqual(SourceVocabulary.watchBooleanYes, "yes")
        XCTAssertEqual(SourceVocabulary.watchBooleanNo, "no")
        XCTAssertEqual(SourceVocabulary.watchActivationActivated, "activated")
        XCTAssertEqual(SourceVocabulary.watchActivationInactive, "inactive")
        XCTAssertEqual(SourceVocabulary.watchActivationNotActivated, "not activated")
        XCTAssertEqual(SourceVocabulary.watchRelativeJustNow, "just now")
        XCTAssertEqual(SourceVocabulary.watchShareDiagnosticsLabel, "share diagnostics")
        XCTAssertEqual(SourceVocabulary.watchShareDiagnosticsHint, "shares watch diagnostics.")
        XCTAssertEqual(SourceVocabulary.watchPrepareDiagnosticsHint, "prepares watch diagnostics.")
        XCTAssertEqual(SourceVocabulary.watchDiagnosticsExportTitle, "watch diagnostics")
        XCTAssertEqual(SourceVocabulary.watchDiagnosticsExportFileName, "watch-diagnostics.txt")
    }

    func testWatchOwnerVisibleCopyAllowsOnlyRequiredWatchNounsAndAvoidsForbiddenTerms() throws {
        let regex = try NSRegularExpression(pattern: Self.forbiddenWatchPattern, options: [.caseInsensitive])

        for string in self.watchOwnerVisibleStrings {
            let firstScalar = try XCTUnwrap(string.unicodeScalars.first)
            XCTAssertTrue(
                CharacterSet.lowercaseLetters.contains(firstScalar) || CharacterSet.decimalDigits.contains(firstScalar),
                string
            )
            let normalized = self.removingAllowedWatchNouns(from: string)
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            XCTAssertNil(regex.firstMatch(in: normalized, range: range), string)
            XCTAssertFalse(string.localizedCaseInsensitiveContains("always on"), string)
        }
    }

    func testConnectionStandingAndProbeCopyDerivations() {
        XCTAssertEqual(
            SourceVocabulary.standingSyncLine(health: .healthy, syncing: false),
            "connected"
        )
        XCTAssertEqual(
            SourceVocabulary.standingSyncLine(health: .healthy, syncing: true),
            "connected · syncing"
        )
        XCTAssertEqual(
            SourceVocabulary.standingSyncLine(health: .unknown, syncing: true),
            "offline"
        )
        XCTAssertEqual(
            SourceVocabulary.standingSyncLine(health: .degraded, syncing: true),
            "connected · trouble reaching your journal"
        )
        XCTAssertEqual(
            SourceVocabulary.standingSyncLine(health: .degraded, syncing: false),
            "connected · trouble reaching your journal"
        )
        XCTAssertEqual(
            SourceVocabulary.probeChecked(alive: true, milliseconds: 42, relative: "just now"),
            "checked just now — reachable · 42 ms"
        )
        XCTAssertEqual(
            SourceVocabulary.probeChecked(alive: false, milliseconds: 0, relative: "just now"),
            "checked just now — not reachable"
        )
        XCTAssertEqual(SourceVocabulary.probeRelativeLabel(secondsAgo: 5), "just now")
    }

    func testLockedSourceSubtexts() {
        XCTAssertEqual(SourceVocabulary.offSubtext, "not sending to your journal. turn it on any time.")
        XCTAssertEqual(SourceVocabulary.enrollingSubtext, "getting ready — connecting to your journal.")
        XCTAssertEqual(SourceVocabulary.pausedSubtext, "you paused this. resume to start sending again.")
        XCTAssertEqual(SourceVocabulary.needsAttentionSubtext, "something's not getting through.")
        XCTAssertEqual(SourceVocabulary.importerActiveSubtext, "sending to your journal as you share.")
    }

    func testLockedDeleteCopyDoesNotMentionSegments() {
        let strings = [
            SourceVocabulary.deleteJournalUnreachableLine,
        ]

        for string in strings {
            XCTAssertFalse(string.contains("segment"))
        }
    }

    func testLockedShareImportCopy() {
        XCTAssertEqual(ShareImportCopy.dismiss, "dismiss")
        XCTAssertEqual(ShareImportCopy.savedAccessibilityLabel, "saved")
        XCTAssertEqual(
            ShareImportCopy.failureMessage(plainReason: "{plain reason}"),
            "couldn't save this — {plain reason}. nothing was added."
        )
    }

    func testRetiredOwnerVisibleCopyStaysRetired() {
        let strings = self.allOwnerVisibleStrings
        let retiredExactStrings = [
            "what sol made from it",
            "open in convey ↗",
            "open your journal in convey ↗",
            "journal dashboard",
        ]

        for retired in retiredExactStrings {
            XCTAssertFalse(strings.contains(retired))
        }
        for string in strings {
            XCTAssertFalse(string.contains("back online"))
        }
    }

    func testLodeCOwnerVisibleCopyStaysLowercaseAndAvoidsForbiddenTerms() throws {
        let regex = try NSRegularExpression(pattern: Self.forbiddenLodeCPattern, options: [.caseInsensitive])
        for string in self.lodeCOwnerVisibleStrings {
            let firstScalar = try XCTUnwrap(string.unicodeScalars.first)
            XCTAssertTrue(
                CharacterSet.lowercaseLetters.contains(firstScalar) || CharacterSet.decimalDigits.contains(firstScalar),
                string
            )
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            XCTAssertNil(regex.firstMatch(in: string, range: range), string)
        }
    }

    private static let forbiddenLodeCTerms = [
        "capture",
        "record",
        "recording",
        "keeper",
        "assistant",
        "monitor",
        "track",
        "collect",
        "watch",
        "server",
        "service",
        "user",
    ]

    private static var forbiddenLodeCPattern: String {
        let alternation = self.forbiddenLodeCTerms
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return #"(?<![A-Za-z0-9_])("# + alternation + #")(?![A-Za-z0-9_])"#
    }

    private static let forbiddenWatchTerms = [
        "capture",
        "record",
        "recording",
        "keeper",
        "assistant",
        "monitor",
        "track",
        "collect",
        "watches",
        "watched",
        "watching",
        "server",
        "service",
    ]

    private static var forbiddenWatchPattern: String {
        let alternation = self.forbiddenWatchTerms
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return #"(?<![A-Za-z0-9_])("# + alternation + #")(?![A-Za-z0-9_])"#
    }

    private func removingAllowedWatchNouns(from string: String) -> String {
        string
            .replacingOccurrences(of: "Watch app", with: "")
            .replacingOccurrences(of: "watch audio", with: "")
            .replacingOccurrences(of: "your watch", with: "")
            .replacingOccurrences(of: "watch", with: "")
    }

    private var watchOwnerVisibleStrings: [String] {
        [
            SourceVocabulary.watchNotSupported,
            SourceVocabulary.watchNoWatchPaired,
            SourceVocabulary.watchAppNotInstalled,
            SourceVocabulary.watchSourceDisplayName,
            SourceVocabulary.watchLinkConnected,
            SourceVocabulary.watchLinkNotConnected,
            SourceVocabulary.watchNoContextSubtext,
            SourceVocabulary.watchIdleSubtext,
            SourceVocabulary.watchListeningSubtext,
            SourceVocabulary.watchInstallTitle,
            SourceVocabulary.watchInstallInstruction,
            SourceVocabulary.watchStateBlockTitle,
            SourceVocabulary.watchDeviceBlockTitle,
            SourceVocabulary.watchDiagnosticsBlockTitle,
            SourceVocabulary.watchTechnicalDetailTitle,
            SourceVocabulary.watchReceivedLabel,
            SourceVocabulary.watchWaitingLabel,
            SourceVocabulary.watchHandedToJournalLabel,
            SourceVocabulary.watchLastSyncLabel,
            SourceVocabulary.watchLastSyncNever,
            SourceVocabulary.watchActivationLabel,
            SourceVocabulary.watchPairedWithPhoneLabel,
            SourceVocabulary.watchInstalledLabel,
            SourceVocabulary.watchLastReceivedLabel,
            SourceVocabulary.watchLastReceivedNever,
            SourceVocabulary.watchLastStagingDetailLabel,
            SourceVocabulary.watchLastSyncDetailLabel,
            SourceVocabulary.watchLastUploadErrorLabel,
            SourceVocabulary.watchStatusLabel,
            SourceVocabulary.watchDetailNone,
            SourceVocabulary.watchBooleanYes,
            SourceVocabulary.watchBooleanNo,
            SourceVocabulary.watchActivationActivated,
            SourceVocabulary.watchActivationInactive,
            SourceVocabulary.watchActivationNotActivated,
            SourceVocabulary.watchRelativeJustNow,
            SourceVocabulary.watchShareDiagnosticsLabel,
            SourceVocabulary.watchShareDiagnosticsHint,
            SourceVocabulary.watchPrepareDiagnosticsHint,
            SourceVocabulary.watchDiagnosticsExportTitle,
            SourceVocabulary.onThisPhoneWatchAudioSourceLabel,
        ]
    }

    private var lodeCOwnerVisibleStrings: [String] {
        [
            SourceVocabulary.onThisPhoneSourceLabel,
            SourceVocabulary.onThisPhoneFailureReasonLabel,
            SourceVocabulary.onThisPhoneFailureStatusLabel,
            SourceVocabulary.onThisPhoneObserverAudioSourceLabel,
            SourceVocabulary.onThisPhoneOmiAudioSourceLabel,
            SourceVocabulary.onThisPhoneFailureRowHint,
            SourceVocabulary.onThisPhoneFailureAttemptStatus(count: 1),
            SourceVocabulary.onThisPhoneFailureAttemptStatus(count: 5),
            SourceVocabulary.standingConnected,
            SourceVocabulary.standingSyncing,
            SourceVocabulary.standingOffline,
            SourceVocabulary.standingDegraded,
            SourceVocabulary.transferRateLabel,
            SourceVocabulary.transferRateIdle,
            SourceVocabulary.checkConnection,
            SourceVocabulary.probeReachable,
            SourceVocabulary.standingSyncLine(health: .healthy, syncing: true),
            SourceVocabulary.standingSyncLine(health: .healthy, syncing: false),
            SourceVocabulary.standingSyncLine(health: .degraded, syncing: false),
            SourceVocabulary.standingSyncLine(health: .unknown, syncing: false),
            SourceVocabulary.probeChecked(alive: true, milliseconds: 42, relative: "just now"),
            SourceVocabulary.probeChecked(alive: false, milliseconds: 0, relative: "just now"),
            SourceVocabulary.migrationHeadlineUpToDate,
            SourceVocabulary.syncingPulse,
            SourceVocabulary.syncedHeadline,
            SourceVocabulary.syncedBody,
            SourceVocabulary.offlineSafeLine,
            SourceVocabulary.needsAttentionRow(count: 2),
            SourceVocabulary.migrationHeadlineSyncing(count: 1),
            SourceVocabulary.migrationHeadlineSyncing(count: 2),
            SourceVocabulary.lastActiveLine(relative: "just now"),
            SourceVocabulary.onThisPhoneFailureRetryableMessage(count: 1),
            SourceVocabulary.onThisPhoneFailureRetryableMessage(count: 5),
            SourceVocabulary.onThisPhoneFailurePermanentMessage(reason: SourceVocabulary.onThisPhoneFailureReasonNetwork),
            SourceVocabulary.onThisPhoneFailureReasonNetwork,
            SourceVocabulary.onThisPhoneFailureReasonTimeout,
            SourceVocabulary.onThisPhoneFailureReasonServer,
            SourceVocabulary.onThisPhoneFailureReasonUnknown,
            SourceVocabulary.onThisPhoneFailureLastTried(datePhrase: "today at 3:00 PM"),
            SourceVocabulary.onThisPhoneAllQuietHeadline,
            SourceVocabulary.onThisPhoneAllQuietBody,
        ]
    }

    private var allOwnerVisibleStrings: [String] {
        [
            SourceState.off.label,
            SourceState.enrolling.label,
            SourceState.active.label,
            SourceState.paused.label,
            SourceState.needsAttention.label,
            SourceVocabulary.offSubtext,
            SourceVocabulary.enrollingSubtext,
            SourceVocabulary.pausedSubtext,
            SourceVocabulary.needsAttentionSubtext,
            SourceVocabulary.needsAttention,
            SourceVocabulary.observerActiveSubtext,
            SourceVocabulary.importerActiveSubtext,
            SourceVocabulary.shareAlwaysOnSubtext,
            SourceVocabulary.shareAlwaysOnExplainer,
            SourceVocabulary.shareSheetDisplayName,
            SourceVocabulary.shareSendingProgress,
            SourceVocabulary.shareDeliveredProgress,
            SourceVocabulary.sendStateSaved,
            SourceVocabulary.sendStateSending,
            SourceVocabulary.sendStateCompactSaved,
            SourceVocabulary.sendStateCompactOnTheWay,
            SourceVocabulary.sendStateCompactInJournal,
            SourceVocabulary.experiencingAlongsideYouHeader,
            SourceVocabulary.bringingInYourselfHeader,
            SourceVocabulary.trustLineUnpaired,
            SourceVocabulary.trustLineConfigured,
            SourceVocabulary.recentEmpty,
            SourceVocabulary.recentFailed,
            SourceVocabulary.notConnectedRowAffordance,
            SourceVocabulary.sourcesConnectBanner,
            SourceVocabulary.zeroActiveSummary,
            SourceVocabulary.whatItAdds,
            SourceVocabulary.pendingSeam,
            SourceVocabulary.removeSeam,
            SourceVocabulary.importerWhatItAdds,
            SourceVocabulary.onThisPhone,
            SourceVocabulary.dayLocalityNoJournal,
            SourceVocabulary.journalConnected,
            SourceVocabulary.journalOffline,
            SourceVocabulary.yourSolstoneTitle,
            SourceVocabulary.dayHomeAskBarHint,
            SourceVocabulary.askBarOffline,
            SourceVocabulary.chatNavTitle,
            SourceVocabulary.chatComposerPlaceholder,
            SourceVocabulary.chatEmptyHeading,
            SourceVocabulary.chatEmptyBody,
            SourceVocabulary.chatEmptySeed1,
            SourceVocabulary.chatEmptySeed2,
            SourceVocabulary.chatOfflineBanner,
            SourceVocabulary.chatPendingStatusA11y,
            SourceVocabulary.chatFailedStatusA11y,
            SourceVocabulary.chatTypingA11y,
            SourceVocabulary.chatSendA11y,
            SourceVocabulary.chatAckBubble,
            SourceVocabulary.chatFoldNotificationBody,
            SourceVocabulary.chatFoldAnchorTitle,
            SourceVocabulary.chatFoldInlineAskPrefix,
            SourceVocabulary.chatFoldOriginalQuestionUnavailable,
            SourceVocabulary.chatTalentDetailTitle,
            SourceVocabulary.chatTalentRunningTitle,
            SourceVocabulary.chatTalentQueuedTitle,
            SourceVocabulary.chatTalentQueuedFallback,
            SourceVocabulary.chatTalentTaskFallback,
            SourceVocabulary.chatTalentDetailEmpty,
            SourceVocabulary.chatErrorEmptyReply,
            SourceVocabulary.chatErrorServer,
            SourceVocabulary.chatErrorGeneric,
            SourceVocabulary.chatErrorDecode,
            SourceVocabulary.chatPartialHonestLine,
            SourceVocabulary.chatAnswerFailedLine,
            SourceVocabulary.chatRetryAnswer,
            SourceVocabulary.chatOfferYes,
            SourceVocabulary.chatOfferNo,
            SourceVocabulary.chatSupportCapacityFrom,
            SourceVocabulary.chatSupportCapacityTo,
            SourceVocabulary.chatSupportCapacitySub,
            SourceVocabulary.chatDraftReviewTitle,
            SourceVocabulary.chatDraftConfirm,
            SourceVocabulary.chatDraftCancel,
            SourceVocabulary.chatDraftDiagnosticsIncluded,
            SourceVocabulary.chatSourceOpenTitle,
            SourceVocabulary.chatSourceSeparator,
            SourceVocabulary.chatSourceCount(1),
            SourceVocabulary.chatSourceCount(2),
            SourceVocabulary.chatQueueCapacityLine(count: 2),
            SourceVocabulary.chatSourcesPillA11yCollapsed(count: 2),
            SourceVocabulary.chatSourcesPillA11yExpanded(count: 1),
            SourceVocabulary.onThisPhoneScope,
            SourceVocabulary.onThisPhoneScopeConnected,
            SourceVocabulary.onThisPhoneScopeOfflinePaired,
            SourceVocabulary.onThisPhoneEmpty,
            SourceVocabulary.onThisPhoneAllQuietHeadline,
            SourceVocabulary.onThisPhoneAllQuietBody,
            SourceVocabulary.onThisPhoneNotBackedUp,
            SourceVocabulary.onThisPhoneTurnOnSourceButton,
            SourceVocabulary.migrationStageOnThisPhone,
            SourceVocabulary.migrationStageOnItsWay,
            SourceVocabulary.migrationStageInYourJournal,
            SourceVocabulary.migrationHeadlineUpToDate,
            SourceVocabulary.syncingPulse,
            SourceVocabulary.syncedHeadline,
            SourceVocabulary.syncedBody,
            SourceVocabulary.offlineSafeLine,
            SourceVocabulary.needsAttentionRow(count: 2),
            SourceVocabulary.migrationHeadlineSyncing(count: 1),
            SourceVocabulary.migrationHeadlineSyncing(count: 2),
            SourceVocabulary.lastActiveLine(relative: "just now"),
            SourceVocabulary.migrationStageCount(2, stage: SourceVocabulary.migrationStageOnItsWay),
            SourceVocabulary.onThisPhoneAgedBacklog(count: 2),
            SourceVocabulary.onThisPhoneLocationRowLabel(count: 2),
            SourceVocabulary.yourJournalSection,
            SourceVocabulary.transferRateLabel,
            SourceVocabulary.transferRateIdle,
            SourceVocabulary.details,
            SourceVocabulary.notProvided,
            SourceVocabulary.originAppNotProvided,
            SourceVocabulary.rawOriginalUnavailable,
            SourceVocabulary.openJournalLink,
            SourceVocabulary.openInJournal,
            SourceVocabulary.onThisPhoneJournalHintSaved,
            SourceVocabulary.onThisPhoneJournalHintLocationSaved,
            SourceVocabulary.onThisPhoneJournalHintPending,
            SourceVocabulary.onThisPhoneJournalHintUnreachable,
            SourceVocabulary.onThisPhoneJournalHintLocationUnreachable,
            SourceVocabulary.onThisPhoneDropFromPhone,
            SourceVocabulary.onThisPhoneDropConfirmTitle,
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .savedOnThisPhone),
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .inYourJournal),
            SourceVocabulary.onThisPhoneDropSnackbar(descriptor: "1m 15s of audio"),
            SourceVocabulary.onThisPhoneDropAudioDescriptor(duration: "1m 15s"),
            SourceVocabulary.onThisPhoneDropLocationDescriptor(count: 2),
            SourceVocabulary.onThisPhoneFileLabel,
            SourceVocabulary.onThisPhoneWhenLabel,
            SourceVocabulary.onThisPhoneObservationsLabel,
            SourceVocabulary.onThisPhoneSourceLabel,
            SourceVocabulary.onThisPhoneFailureReasonLabel,
            SourceVocabulary.onThisPhoneFailureStatusLabel,
            SourceVocabulary.onThisPhoneObserverAudioSourceLabel,
            SourceVocabulary.onThisPhoneOmiAudioSourceLabel,
            SourceVocabulary.onThisPhoneFailureRowHint,
            SourceVocabulary.onThisPhoneFailureAttemptStatus(count: 5),
            SourceVocabulary.onThisPhoneFailureRetryableMessage(count: 1),
            SourceVocabulary.onThisPhoneFailureRetryableMessage(count: 5),
            SourceVocabulary.onThisPhoneFailurePermanentMessage(reason: SourceVocabulary.onThisPhoneFailureReasonNetwork),
            SourceVocabulary.onThisPhoneFailureReasonNetwork,
            SourceVocabulary.onThisPhoneFailureReasonTimeout,
            SourceVocabulary.onThisPhoneFailureReasonServer,
            SourceVocabulary.onThisPhoneFailureReasonUnknown,
            SourceVocabulary.onThisPhoneFailureLastTried(datePhrase: "today at 3:00 PM"),
            SourceVocabulary.audioPlaybackObserverActiveHint,
            SourceVocabulary.audioPlaybackPlayLabel,
            SourceVocabulary.audioPlaybackPauseLabel,
            SourceVocabulary.audioPlaybackHint,
            SourceVocabulary.onThisPhoneNavigationTitle(source: "audio", shortTime: "9:30 AM"),
            SourceVocabulary.onThisPhoneAudioSummary(duration: "1m 15s"),
            SourceVocabulary.onThisPhoneLocationSummary(count: 2),
            SourceVocabulary.onThisPhoneObservedSummary(relativeDay: "today", shortTime: "9:30 AM"),
            SourceVocabulary.onThisPhoneShareSummary(originApp: "Files", relativeDay: "today", shortTime: "9:30 AM"),
            SourceVocabulary.onThisPhoneFileDetail(filename: "item.pdf", size: "2 KB"),
            SourceVocabulary.onThisPhoneFixCount(count: 2),
            SourceVocabulary.connectJournalIntro,
            SourceVocabulary.connectDoorOwnTitle,
            SourceVocabulary.connectDoorOwnSubtitle,
            SourceVocabulary.connectDoorHostedTitle,
            SourceVocabulary.connectDoorHostedSubtitle,
            SourceVocabulary.pairingLinked,
            SourceVocabulary.pairingAlreadyConnected,
            SourceVocabulary.pairingReconnected,
            SourceVocabulary.pairingReconnecting,
            SourceVocabulary.retry,
            SourceVocabulary.drop,
            SourceVocabulary.cancel,
            SourceVocabulary.undo,
            SourceVocabulary.turnOn,
            SourceVocabulary.pause,
            SourceVocabulary.resume,
            SourceVocabulary.delete,
            SourceVocabulary.deleteJournalUnreachableLine,
            SourceVocabulary.journalTunnel,
            SourceVocabulary.probeNotReachable,
            ShareImportCopy.dismiss,
            ShareImportCopy.savedAccessibilityLabel,
        ]
    }
}
