// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class SourceVocabularyTests: XCTestCase {
    func testLockedSourceStateLabels() {
        XCTAssertEqual(SourceState.off.label, "off")
        XCTAssertEqual(SourceState.enrolling.label, "setting up")
        XCTAssertEqual(SourceState.readyToSetUp.label, "ready to set up")
        XCTAssertEqual(SourceState.checking.label, "checking…")
        XCTAssertEqual(SourceState.active.label, "on")
        XCTAssertEqual(SourceState.paused.label, "paused")
        XCTAssertEqual(SourceState.needsAttention.label, "needs attention")
    }

    func testLockedSourceStateSymbols() {
        XCTAssertEqual(SourceState.off.symbol, "power.circle")
        XCTAssertEqual(SourceState.enrolling.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(SourceState.readyToSetUp.symbol, "plus.circle")
        XCTAssertEqual(SourceState.checking.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(SourceState.active.symbol, "checkmark.circle")
        XCTAssertEqual(SourceState.paused.symbol, "pause.circle")
        XCTAssertEqual(SourceState.needsAttention.symbol, "exclamationmark.triangle")
    }

    func testJournalLivesActionReflectsPairingState() {
        XCTAssertEqual(SourceVocabulary.journalLivesAction(isPaired: false), "connect")
        XCTAssertEqual(SourceVocabulary.journalLivesAction(isPaired: true), "re-pair")
    }

    func testStandingSyncFootnoteCopyReflectsSustainingState() {
        XCTAssertEqual(
            SourceVocabulary.standingSyncFootnote(sustaining: true),
            "syncs while the solstone app is open, and keeps going in the background while location is on."
        )
        XCTAssertEqual(
            SourceVocabulary.standingSyncFootnote(sustaining: false),
            "the solstone app syncs to your journal while it's open, and keeps going in the background for as long as iOS allows. with location on, that lasts longer."
        )
    }

    func testNotConnectedRowAffordanceCopyReflectsPairingState() {
        XCTAssertEqual(
            SourceVocabulary.notConnectedRowAffordance(isJournalPaired: false),
            "connect a journal first."
        )
        XCTAssertEqual(
            SourceVocabulary.notConnectedRowAffordance(isJournalPaired: true),
            "opens when your journal reconnects."
        )
    }

    func testTransferRateValueFormatsApproximateThroughput() {
        let kbRate = SourceVocabulary.transferRateValue(bytesPerSecond: 240_000)
        XCTAssertTrue(kbRate.contains("~"), kbRate)
        XCTAssertTrue(kbRate.contains("KB/s"), kbRate)

        let mbRate = SourceVocabulary.transferRateValue(bytesPerSecond: 1_300_000)
        XCTAssertTrue(mbRate.contains("MB/s"), mbRate)
    }

    func testLockedOwnerSourceCopy() {
        XCTAssertEqual(SourceVocabulary.trustLineConfigured, "syncs only to your journal")
        XCTAssertEqual(SourceVocabulary.shareSendingProgress, "sending to your journal…")
        XCTAssertEqual(SourceVocabulary.shareDeliveredProgress, "saved to your journal")
        XCTAssertEqual(SourceVocabulary.addMoreTitle, "add more")
        XCTAssertEqual(SourceVocabulary.addMoreSubline, "sources and devices")
        XCTAssertEqual(SourceVocabulary.importTitle, "import")
        XCTAssertEqual(SourceVocabulary.importSubline, "photos, files, anything")
        XCTAssertEqual(SourceVocabulary.giveThisATileOnHome, "give this a tile on home")
        XCTAssertEqual(SourceVocabulary.hidingThisNeverTurnsItOff, "hiding this never turns it off.")
        XCTAssertEqual(SourceVocabulary.whatItAddsTitle, "what it adds")
        XCTAssertEqual(SourceVocabulary.openSettings, "open iOS Settings")
        XCTAssertEqual(
            SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: false),
            "share is on. anything you send from another app is on this device until you connect a journal."
        )
        XCTAssertEqual(
            SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: true),
            "share is on. anything you send from the share sheet comes into your journal here."
        )
        XCTAssertEqual(SourceVocabulary.sendStateCompactSaved, "waiting to sync")
        XCTAssertEqual(SourceVocabulary.sendStateCompactOnTheWay, "on the way")
        XCTAssertEqual(SourceVocabulary.sendStateCompactInJournal, "in your journal")
        XCTAssertEqual(SourceVocabulary.tryNow, "try now")
        XCTAssertEqual(SourceVocabulary.waitingToSync, "waiting to sync")
        XCTAssertFalse(SourceVocabulary.onThisPhoneWaitingExplain.isEmpty)
        XCTAssertTrue(SourceVocabulary.onThisPhoneWaitingExplain.contains("still on this device"))
        XCTAssertEqual(
            SourceVocabulary.audioEnrollmentValue,
            "what you say and the sound around you, on this device until you connect a journal. turn it on only when you want to share audio."
        )
        XCTAssertEqual(SourceVocabulary.turnOnAudio, "turn on audio")
        XCTAssertEqual(SourceVocabulary.onThisPhone, "on this device")
        XCTAssertEqual(SourceVocabulary.yourJournalSection, "your journal")
        XCTAssertEqual(SourceVocabulary.transferRateLabel, "transfer rate")
        XCTAssertEqual(SourceVocabulary.transferRateIdle, "idle")
        XCTAssertEqual(SourceVocabulary.details, "details")
        XCTAssertEqual(SourceVocabulary.dayLocalityNoJournal, "on this device · not paired")
        XCTAssertEqual(SourceVocabulary.journalConnected, "your journal · connected")
        XCTAssertEqual(SourceVocabulary.journalOffline, "your journal · offline")
        XCTAssertEqual(SourceVocabulary.openInJournal, "open in journal")
        XCTAssertEqual(
            SourceVocabulary.connectJournalIntro,
            "your memories are on this device. connect a journal and everything you've shared so far flows in."
        )
        XCTAssertEqual(SourceVocabulary.connectDoorOwnTitle, "your own journal")
        XCTAssertEqual(SourceVocabulary.connectDoorOwnSubtitle, "pair this device to your journal running on your computer.")
        XCTAssertEqual(SourceVocabulary.connectDoorOnYourPhoneTitle, "on this device")
        XCTAssertEqual(
            SourceVocabulary.connectDoorOnYourPhoneBody,
            "your journal as its own app, right on this device."
        )
        XCTAssertEqual(
            SourceVocabulary.connectJournalFloorLine,
            "no journal yet? that's fine. everything the solstone app takes in is on this device."
        )
        XCTAssertEqual(SourceVocabulary.connectJournalHowJournalsWork, "how journals work →")
        XCTAssertEqual(SourceVocabulary.journalLivesTitle, "where your journal lives")
        XCTAssertEqual(SourceVocabulary.journalLivesPromise, "your journal is always private, only yours.")
        XCTAssertEqual(SourceVocabulary.journalLivesOwnTitle, "your own journal")
        XCTAssertEqual(
            SourceVocabulary.journalLivesOwnBody,
            "pair to your journal on your computer. everything you've shared so far flows in."
        )
        XCTAssertEqual(SourceVocabulary.journalLivesOnYourPhoneTitle, "on this device")
        XCTAssertEqual(
            SourceVocabulary.journalLivesOnYourPhoneBody,
            "your journal as its own app, right on this device."
        )
        XCTAssertEqual(
            SourceVocabulary.journalLivesCachedLine,
            "right now, just your memories are on this device, waiting to be processed."
        )
        XCTAssertEqual(SourceVocabulary.journalLivesComingLater, "coming later")
        XCTAssertEqual(SourceVocabulary.pairingLinked, "journal connected")
        XCTAssertEqual(SourceVocabulary.pairingAlreadyConnected, "this journal is already connected")
        XCTAssertEqual(SourceVocabulary.pairingReconnected, "journal connection updated")
        XCTAssertEqual(SourceVocabulary.pairingReconnecting, "reconnecting…")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneScope,
            "everything you've shared, on this device until you connect a journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneScopeConnected,
            "everything you've shared, moving into your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneScopeOfflinePaired,
            "everything you've shared, ready for your journal when it reconnects."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneEmpty,
            "nothing here yet. turn on a source and the solstone app takes in what you share with it, and it goes into your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneTruthLine,
            "your memories are on this device and not processed until you connect a journal."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneConnectJournalButton, "connect journal")
        XCTAssertEqual(SourceVocabulary.onThisPhoneAllQuietHeadline, "all quiet")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAllQuietBody,
            "everything you've shared is in your journal. new moments rest here on their way through."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneNotBackedUp,
            "nothing here is backed up yet. connect a journal to keep a copy."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneTurnOnSourceButton, "turn on a source")
        XCTAssertEqual(SourceVocabulary.migrationStageOnThisPhone, "on this device")
        XCTAssertEqual(SourceVocabulary.migrationStageOnItsWay, "on its way")
        XCTAssertEqual(SourceVocabulary.migrationStageInYourJournal, "in your journal")
        XCTAssertEqual(SourceVocabulary.migrationHeadlineUpToDate, "your journal is up to date")
        XCTAssertEqual(SourceVocabulary.syncingPulse, "syncing to your journal…")
        XCTAssertEqual(SourceVocabulary.syncedHeadline, "all caught up")
        XCTAssertEqual(SourceVocabulary.syncedBody, "everything is in your journal")
        XCTAssertEqual(SourceVocabulary.offlineSafeLine, "on this device")
        XCTAssertEqual(SourceVocabulary.migrationHeadlineSyncing(count: 1), "syncing 1 segment to your journal")
        XCTAssertEqual(SourceVocabulary.migrationHeadlineSyncing(count: 2), "syncing 2 segments to your journal")
        XCTAssertEqual(SourceVocabulary.lastActiveLine(relative: "just now"), "last active · just now")
        XCTAssertEqual(
            SourceVocabulary.migrationStageCount(12, stage: SourceVocabulary.migrationStageOnItsWay),
            "12 on its way"
        )
        XCTAssertEqual(SourceVocabulary.magicMomentShownHeadline, "it's on this device now")
        XCTAssertEqual(
            SourceVocabulary.magicMomentShownBody,
            "the solstone app just took in your first memory. it's on this device until you connect a journal."
        )
        XCTAssertEqual(SourceVocabulary.magicMomentShownSecondary, "connect a journal whenever →")
        XCTAssertEqual(SourceVocabulary.magicMomentPendingHeadline, "your first audio memory is getting ready")
        XCTAssertEqual(SourceVocabulary.magicMomentPendingBody, "when you stop, it will be on this device.")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAgedBacklog(count: 1),
            "1 memory is on this device. connect a journal whenever you're ready."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAgedBacklog(count: 12),
            "12 memories are on this device. connect a journal whenever you're ready."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationRowLabel(count: 1), "1 memory")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationRowLabel(count: 12), "12 memories")
        XCTAssertEqual(SourceVocabulary.openJournalLink, "open journal ↗")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneJournalHintSaved,
            "this was added to your journal automatically. open it to read the full thing."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneJournalHintLocationSaved, "open it to see these places on a map.")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneJournalHintPending,
            "not in your journal yet — it'll appear once it's sent."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneJournalHintUnreachable, "connect a journal first.")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneJournalHintLocationUnreachable,
            "connect a journal to see these places on a map."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropFromPhone, "drop from this device")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropConfirmTitle, "drop this from this device?")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .savedOnThisPhone),
            "this is only on this device. dropping it means it won't reach your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .sending),
            "this is only on this device. dropping it means it won't reach your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .needsAttention),
            "this is only on this device. dropping it means it won't reach your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: .inYourJournal),
            "this is in your journal. dropping just clears it from this device."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropSnackbar(descriptor: "1m 15s of audio"), "dropped “1m 15s of audio”.")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropAudioDescriptor(duration: "1m 15s"), "1m 15s of audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropLocationDescriptor(count: 2), "2 memories")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFileLabel, "file")
        XCTAssertEqual(SourceVocabulary.onThisPhoneWhenLabel, "when")
        XCTAssertEqual(SourceVocabulary.onThisPhoneObservationsLabel, "memories")
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
            "this can't go to your journal. the connection wasn't available. you can remove it from this device."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonNetwork, "the connection wasn't available")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonTimeout, "the connection took too long")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonServer, "your journal couldn't accept it")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFailureReasonUnknown, "something got in the way")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneFailureLastTried(datePhrase: "today at 3:00 PM"),
            "last tried today at 3:00 PM"
        )
        XCTAssertEqual(SourceVocabulary.audioPlaybackObserverActiveHint, "pause to play this")
        XCTAssertEqual(SourceVocabulary.audioPlaybackPlayLabel, "play audio")
        XCTAssertEqual(SourceVocabulary.audioPlaybackPauseLabel, "pause audio")
        XCTAssertEqual(SourceVocabulary.audioPlaybackHint, "plays this audio from this device.")
        XCTAssertEqual(SourceVocabulary.onThisPhoneNavigationTitle(source: "audio", shortTime: nil), "audio")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneNavigationTitle(source: "audio", shortTime: "9:30 AM"),
            "audio · 9:30 AM"
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneAudioSummary(duration: "1m 15s"), "1m 15s of audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationSummary(count: 1), "1 memory")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationSummary(count: 3), "3 memories")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneObservedSummary(relativeDay: "today", shortTime: "9:30 AM"),
            "on this device · today at 9:30 AM"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneObservedSummary(relativeDay: "today", shortTime: nil),
            "on this device · today"
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneObservedSummary(relativeDay: nil, shortTime: nil),
            "on this device"
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
        XCTAssertEqual(SourceVocabulary.checkConnection, "check connection")
        XCTAssertEqual(SourceVocabulary.probeReachable, "reachable")
        XCTAssertEqual(SourceVocabulary.probeNotReachable, "not reachable")
        XCTAssertEqual(SourceVocabulary.sourceStateReadyToSetUpLabel, "ready to set up")
        XCTAssertEqual(SourceVocabulary.sourceStateCheckingLabel, "checking…")
        XCTAssertEqual(SourceVocabulary.watchSourceDisplayName, "watch")
        XCTAssertEqual(SourceVocabulary.watchLinkConnected, "phone link: in range")
        XCTAssertEqual(SourceVocabulary.watchLinkNotConnected, "phone link: out of range")
        XCTAssertEqual(SourceVocabulary.watchPipelineUnknown, "—")
        XCTAssertEqual(
            SourceVocabulary.watchPipelineRelayStuckReason,
            "your watch has segments saved, but this iphone has not received anything for a while."
        )
        XCTAssertEqual(
            SourceVocabulary.watchPipelineHandoffStuckReason,
            "segments are on this iphone and waiting to reach your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.watchPipelineOrphanStuckReason,
            "some segments stalled before they reached your journal."
        )
        XCTAssertEqual(SourceVocabulary.watchPipelineReportedGroupLabel, "reported by your watch")
        XCTAssertEqual(SourceVocabulary.watchPipelineKnownGroupLabel, "known on this iphone")
        XCTAssertEqual(SourceVocabulary.watchStuckNoticeTitle, "sync needs attention")
        XCTAssertEqual(
            SourceVocabulary.watchPipelineRelayStuckNextStep,
            "keep your watch near this iphone. open the solstone app on your watch if this does not move."
        )
        XCTAssertEqual(
            SourceVocabulary.watchPipelineHandoffStuckNextStep,
            "keep the solstone app open here while your journal catches up."
        )
        XCTAssertEqual(
            SourceVocabulary.watchPipelineOrphanStuckNextStep,
            "open the solstone app on your watch and keep it near this iphone so they can come over again."
        )
        XCTAssertEqual(SourceVocabulary.watchActivationFailedSubtext, "can't check your watch right now.")
        XCTAssertEqual(SourceVocabulary.watchNoWatchPairedSubtext, "no watch paired with this iphone.")
        XCTAssertEqual(SourceVocabulary.watchReadyToSetUpSubtext, "the solstone app can be on your watch. tap to set it up.")
        XCTAssertEqual(SourceVocabulary.watchInstalledNeverOpenedSubtext, "installed. now open the solstone app on your watch.")
        XCTAssertEqual(SourceVocabulary.watchReceivingNowSubtext, "receiving from your watch")
        XCTAssertEqual(SourceVocabulary.watchIdleNowSubtext, "start the solstone app on your watch when you want it with you.")
        XCTAssertEqual(SourceVocabulary.watchWaitingToSyncFromWatch(1), "1 waiting to sync from your watch")
        XCTAssertEqual(SourceVocabulary.watchWaitingToSyncFromWatch(3), "3 waiting to sync from your watch")
        XCTAssertEqual(SourceVocabulary.watchListeningSubtext, "on your watch, taking in audio")
        XCTAssertEqual(SourceVocabulary.watchSteadyObservingHeadline, "on right now")
        XCTAssertEqual(SourceVocabulary.watchObservingSentenceBase, "taking in audio on your watch")
        XCTAssertEqual(SourceVocabulary.watchObservingSentence(elapsedMinutes: nil), "taking in audio on your watch")
        XCTAssertEqual(SourceVocabulary.watchObservingSentence(elapsedMinutes: 0), "taking in audio on your watch")
        XCTAssertEqual(SourceVocabulary.watchObservingSentence(elapsedMinutes: 2), "taking in audio on your watch · 2 min")
        XCTAssertEqual(SourceVocabulary.watchSteadyReceivingHeadline, "receiving now")
        XCTAssertEqual(SourceVocabulary.watchSteadyWatchWaitingHeadline, "saved on your watch")
        XCTAssertEqual(
            SourceVocabulary.watchSteadyWatchWaitingSentence(1),
            "1 on your watch, waiting to come over. keep your watch nearby."
        )
        XCTAssertEqual(
            SourceVocabulary.watchSteadyWatchWaitingSentence(2),
            "2 on your watch, waiting to come over. keep your watch nearby."
        )
        XCTAssertEqual(SourceVocabulary.watchSteadyPhoneSyncingHeadline, "on this iphone")
        XCTAssertEqual(SourceVocabulary.watchSteadyPhoneSyncingSentence(1), "1 syncing to your journal…")
        XCTAssertEqual(SourceVocabulary.watchSteadyPhoneSyncingSentence(2), "2 syncing to your journal…")
        XCTAssertEqual(SourceVocabulary.watchSteadyCaughtUpSentence, "everything from your watch is in your journal.")
        XCTAssertEqual(SourceVocabulary.watchSteadyQuietHeadline, "quiet right now")
        XCTAssertEqual(SourceVocabulary.watchPresenceConnectedNow, "your watch is connected right now")
        XCTAssertEqual(SourceVocabulary.watchPresenceNeverHeard, "haven't heard from your watch yet")
        XCTAssertEqual(SourceVocabulary.watchPresenceLastHeard(relative: "1m ago"), "last heard from your watch · 1m ago")
        XCTAssertEqual(SourceVocabulary.watchTodayHandedLine(2), "today · handed 2 to your journal")
        XCTAssertEqual(
            SourceVocabulary.watchSteadyDetailsSummary(watchWaiting: 2, phoneWaiting: 3),
            "details · watch 2 · iphone 3 waiting"
        )
        XCTAssertEqual(SourceVocabulary.watchSetupHeader, "the solstone app on your watch")
        XCTAssertEqual(
            SourceVocabulary.watchSetupValueLine,
            "the solstone app on your watch takes in what you share from your wrist, hands it to this iphone, and it all syncs into your journal."
        )
        XCTAssertEqual(
            SourceVocabulary.watchSetupNoWatchBody,
            "pair an apple watch to this iphone and the solstone app can come along on your wrist. everything else in solstone works without one."
        )
        XCTAssertEqual(SourceVocabulary.watchCheckingLine, "checking your watch…")
        XCTAssertEqual(SourceVocabulary.watchSetupInstallTitle, "install the solstone app from the Watch app")
        XCTAssertEqual(
            SourceVocabulary.watchSetupInstallSubline,
            "in My Watch, scroll to Available Apps and tap install next to the solstone app."
        )
        XCTAssertEqual(SourceVocabulary.watchSetupInstallButton, "open the Watch app")
        XCTAssertEqual(SourceVocabulary.watchSetupInstallButtonHint, "opens the Watch app.")
        XCTAssertEqual(SourceVocabulary.watchSetupInstallDisclosureSummary, "don't see the solstone app in the list?")
        XCTAssertEqual(
            SourceVocabulary.watchSetupInstallDisclosureBody,
            "your watch may need watchOS 26 or newer. check Software Update in the Watch app. everything else in solstone works without a watch."
        )
        XCTAssertEqual(SourceVocabulary.watchSetupOpenTitle, "open the solstone app on your watch")
        XCTAssertEqual(
            SourceVocabulary.watchSetupOpenSubline,
            "the solstone app checks in with this iphone the first time it opens."
        )
        XCTAssertEqual(SourceVocabulary.watchSetupFirstMomentTitle, "tap start for your first moment")
        XCTAssertEqual(SourceVocabulary.watchSetupCelebration, "your watch's first memory just landed on this device.")
        XCTAssertEqual(SourceVocabulary.watchSetupStepPending, "pending")
        XCTAssertEqual(SourceVocabulary.watchSetupStepActive, "active")
        XCTAssertEqual(SourceVocabulary.watchSetupStepComplete, "complete")
        XCTAssertEqual(SourceVocabulary.watchStateBlockTitle, "state")
        XCTAssertEqual(SourceVocabulary.watchDiagnosticsBlockTitle, "diagnostics")
        XCTAssertEqual(SourceVocabulary.watchTechnicalDetailTitle, "technical detail")
        XCTAssertEqual(SourceVocabulary.watchReceivedLabel, "received")
        XCTAssertEqual(SourceVocabulary.watchNotYetInJournalLabel, "not yet in your journal")
        XCTAssertEqual(SourceVocabulary.watchHandedToJournalLabel, "handed to your journal")
        XCTAssertEqual(SourceVocabulary.watchLastSyncLabel, "last sync")
        XCTAssertEqual(SourceVocabulary.watchLastSyncNever, "no sync yet")
        XCTAssertEqual(SourceVocabulary.watchActivationLabel, "activation")
        XCTAssertEqual(SourceVocabulary.watchPairedWithPhoneLabel, "paired with this iphone")
        XCTAssertEqual(SourceVocabulary.watchInstalledLabel, "installed")
        XCTAssertEqual(SourceVocabulary.watchLastReceivedLabel, "last received")
        XCTAssertEqual(SourceVocabulary.watchLastReceivedNever, "nothing received yet")
        XCTAssertEqual(SourceVocabulary.watchLastStagingDetailLabel, "last staging detail")
        XCTAssertEqual(SourceVocabulary.watchLastLedgerDetailLabel, "last ledger detail")
        XCTAssertEqual(SourceVocabulary.watchLastSyncDetailLabel, "last sync detail")
        XCTAssertEqual(SourceVocabulary.watchLastUploadErrorLabel, "last upload error")
        XCTAssertEqual(SourceVocabulary.watchStatusLabel, "watch status")
        XCTAssertEqual(SourceVocabulary.watchReachableLabel, "reachable")
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
        XCTAssertEqual(SourceVocabulary.problemReportsToggle, "keep problem reports")
        XCTAssertEqual(
            SourceVocabulary.problemReportsToggleHint,
            "keeps app problem reports on this device so you can share them if you choose."
        )
        XCTAssertEqual(SourceVocabulary.problemReportsTitle, "problem reports")
        XCTAssertEqual(SourceVocabulary.problemReportsRow, "problem reports")
        XCTAssertEqual(SourceVocabulary.problemReportsRowHint, "opens problem reports kept on this device.")
        XCTAssertEqual(SourceVocabulary.problemReportsReportRowHint, "opens report detail.")
        XCTAssertEqual(SourceVocabulary.problemReportsOptedOutTitle, "problem reports are off")
        XCTAssertEqual(
            SourceVocabulary.problemReportsOptedOutBody,
            "turn them on to keep reports on this device when the app quits or gets stuck."
        )
        XCTAssertEqual(SourceVocabulary.problemReportsEmptyTitle, "no problem reports yet")
        XCTAssertEqual(
            SourceVocabulary.problemReportsEmptyBody,
            "reports will appear here if the solstone app quits unexpectedly or gets stuck."
        )
        XCTAssertEqual(SourceVocabulary.problemReportKindCrash, "app quit unexpectedly")
        XCTAssertEqual(SourceVocabulary.problemReportKindHang, "app got stuck")
        XCTAssertEqual(SourceVocabulary.problemReportKindCPUException, "app used too much processing time")
        XCTAssertEqual(SourceVocabulary.problemReportKindDiskWriteException, "app wrote too much to storage")
        XCTAssertEqual(SourceVocabulary.problemReportKindAppLaunch, "app took too long to open")
        XCTAssertEqual(SourceVocabulary.problemReportKindAppExit, "app quit summary")
        XCTAssertEqual(SourceVocabulary.problemReportKindUnknown, "app issue report")
        XCTAssertEqual(SourceVocabulary.problemReportsShare, "share")
        XCTAssertEqual(SourceVocabulary.problemReportsShareHint, "shares this problem report.")
        XCTAssertEqual(SourceVocabulary.problemReportsShareAll, "share all")
        XCTAssertEqual(SourceVocabulary.problemReportsShareAllHint, "shares all problem reports.")
        XCTAssertEqual(SourceVocabulary.problemReportsDelete, "delete")
        XCTAssertEqual(SourceVocabulary.problemReportsDeleteHint, "deletes this problem report.")
        XCTAssertEqual(SourceVocabulary.problemReportsDeleteAll, "delete all")
        XCTAssertEqual(SourceVocabulary.problemReportsDeleteAllHint, "deletes all problem reports.")
        XCTAssertEqual(SourceVocabulary.problemReportsDeleteAllConfirmTitle, "delete all problem reports?")
        XCTAssertEqual(SourceVocabulary.problemReportsDeleteAllConfirmBody, "this removes the reports kept on this device.")
        XCTAssertEqual(SourceVocabulary.problemReportsMissingTitle, "problem report unavailable")
        XCTAssertEqual(SourceVocabulary.problemReportsMissingBody, "it may have already been deleted.")
    }

    func testWatchOwnerVisibleCopyAllowsOnlyRequiredWatchNounsAndAvoidsForbiddenTerms() throws {
        let regex = try NSRegularExpression(pattern: Self.forbiddenWatchPattern, options: [.caseInsensitive])

        for string in self.watchOwnerVisibleStrings {
            let firstScalar = try XCTUnwrap(string.unicodeScalars.first)
            XCTAssertTrue(
                string == SourceVocabulary.watchPipelineUnknown
                    || CharacterSet.lowercaseLetters.contains(firstScalar)
                    || CharacterSet.decimalDigits.contains(firstScalar),
                string
            )
            let normalized = self.removingAllowedWatchNouns(from: string)
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            XCTAssertNil(regex.firstMatch(in: normalized, range: range), string)
            XCTAssertFalse(string.localizedCaseInsensitiveContains("always on"), string)
        }
    }

    func testProbeCopyDerivations() {
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
        XCTAssertEqual(SourceVocabulary.offSubtext(isJournalPaired: false), "turn it on any time.")
        XCTAssertEqual(SourceVocabulary.offSubtext(isJournalPaired: true), "not sending to your journal. turn it on any time.")
        XCTAssertEqual(SourceVocabulary.enrollingSubtext(isJournalPaired: false), "getting ready…")
        XCTAssertEqual(SourceVocabulary.enrollingSubtext(isJournalPaired: true), "getting ready — connecting to your journal.")
        XCTAssertEqual(SourceVocabulary.pausedSubtext, "you paused this. resume to start sending again.")
        XCTAssertEqual(SourceVocabulary.needsAttentionSubtext, "something's not getting through.")
    }

    func testSourceStateSubtextsUseJournalPairingForVisibleAndVoiceOverText() {
        XCTAssertEqual(
            SourceState.off.subtext(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: false),
            "turn it on any time."
        )
        XCTAssertEqual(
            SourceState.off.voiceOverText(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: false),
            "off. turn it on any time."
        )
        XCTAssertEqual(
            SourceState.off.subtext(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: true),
            "not sending to your journal. turn it on any time."
        )
        XCTAssertEqual(
            SourceState.off.voiceOverText(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: true),
            "off. not sending to your journal. turn it on any time."
        )
        XCTAssertEqual(
            SourceState.enrolling.subtext(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: false),
            "getting ready…"
        )
        XCTAssertEqual(
            SourceState.enrolling.voiceOverText(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: false),
            "setting up. getting ready…"
        )
        XCTAssertEqual(
            SourceState.enrolling.subtext(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: true),
            "getting ready — connecting to your journal."
        )
        XCTAssertEqual(
            SourceState.enrolling.voiceOverText(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: true),
            "setting up. getting ready — connecting to your journal."
        )
        XCTAssertNil(SourceState.readyToSetUp.universalSubtext(isJournalPaired: true))
        XCTAssertEqual(
            SourceState.readyToSetUp.voiceOverText(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: true),
            "ready to set up. on."
        )
        XCTAssertNil(SourceState.checking.universalSubtext(isJournalPaired: true))
        XCTAssertEqual(
            SourceState.checking.voiceOverText(activeSubtext: SourceVocabulary.observerActiveSubtext, isJournalPaired: true),
            "checking."
        )
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
            "kept on this phone, only — nowhere else, until you connect a journal",
            "kept here until you connect a journal · connect →",
            "nothing is on right now",
            "install sol on your watch",
            "open the Watch app to install it",
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

    func testEmDashCheckedOwnerVisibleStringsDoNotUseEmDash() {
        for string in self.emDashCheckedOwnerVisibleStrings {
            XCTAssertFalse(string.contains("—"), string)
        }
    }

    func testNotConnectedRowAffordanceRenderSitesPassPairingState() throws {
        let expected = "SourceVocabulary.notConnectedRowAffordance(isJournalPaired: self.appConfig.isPaired)"
        for relativePath in [
            "Sources/Home/ShelfPane.swift",
            "Sources/Location/LocationSourceDetailView.swift",
        ] {
            let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains(expected), relativePath)
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
            SourceVocabulary.sourceStateReadyToSetUpLabel,
            SourceVocabulary.sourceStateCheckingLabel,
            SourceVocabulary.watchSourceDisplayName,
            SourceVocabulary.watchLinkConnected,
            SourceVocabulary.watchLinkNotConnected,
            SourceVocabulary.watchPipelineUnknown,
            SourceVocabulary.watchPipelineRelayStuckReason,
            SourceVocabulary.watchPipelineHandoffStuckReason,
            SourceVocabulary.watchPipelineOrphanStuckReason,
            SourceVocabulary.watchPipelineReportedGroupLabel,
            SourceVocabulary.watchPipelineKnownGroupLabel,
            SourceVocabulary.watchStuckNoticeTitle,
            SourceVocabulary.watchPipelineRelayStuckNextStep,
            SourceVocabulary.watchPipelineHandoffStuckNextStep,
            SourceVocabulary.watchPipelineOrphanStuckNextStep,
            SourceVocabulary.watchPipelineStaleAsOf("1m ago"),
            SourceVocabulary.watchActivationFailedSubtext,
            SourceVocabulary.watchNoWatchPairedSubtext,
            SourceVocabulary.watchReadyToSetUpSubtext,
            SourceVocabulary.watchInstalledNeverOpenedSubtext,
            SourceVocabulary.watchReceivingNowSubtext,
            SourceVocabulary.watchIdleNowSubtext,
            SourceVocabulary.watchWaitingToSyncFromWatch(2),
            SourceVocabulary.watchListeningSubtext,
            SourceVocabulary.watchSteadyObservingHeadline,
            SourceVocabulary.watchObservingSentenceBase,
            SourceVocabulary.watchObservingSentence(elapsedMinutes: 2),
            SourceVocabulary.watchSteadyReceivingHeadline,
            SourceVocabulary.watchSteadyWatchWaitingHeadline,
            SourceVocabulary.watchSteadyWatchWaitingSentence(2),
            SourceVocabulary.watchSteadyPhoneSyncingHeadline,
            SourceVocabulary.watchSteadyPhoneSyncingSentence(2),
            SourceVocabulary.watchSteadyCaughtUpSentence,
            SourceVocabulary.watchSteadyQuietHeadline,
            SourceVocabulary.watchPresenceConnectedNow,
            SourceVocabulary.watchPresenceNeverHeard,
            SourceVocabulary.watchPresenceLastHeard(relative: "1m ago"),
            SourceVocabulary.watchTodayHandedLine(2),
            SourceVocabulary.watchSteadyDetailsSummary(watchWaiting: 2, phoneWaiting: 3),
            SourceVocabulary.watchSetupHeader,
            SourceVocabulary.watchSetupValueLine,
            SourceVocabulary.watchSetupNoWatchBody,
            SourceVocabulary.watchCheckingLine,
            SourceVocabulary.watchSetupInstallTitle,
            SourceVocabulary.watchSetupInstallSubline,
            SourceVocabulary.watchSetupInstallButton,
            SourceVocabulary.watchSetupInstallButtonHint,
            SourceVocabulary.watchSetupInstallDisclosureSummary,
            SourceVocabulary.watchSetupInstallDisclosureBody,
            SourceVocabulary.watchSetupOpenTitle,
            SourceVocabulary.watchSetupOpenSubline,
            SourceVocabulary.watchSetupFirstMomentTitle,
            SourceVocabulary.watchSetupCelebration,
            SourceVocabulary.watchSetupStepPending,
            SourceVocabulary.watchSetupStepActive,
            SourceVocabulary.watchSetupStepComplete,
            SourceVocabulary.watchStateBlockTitle,
            SourceVocabulary.watchDiagnosticsBlockTitle,
            SourceVocabulary.watchTechnicalDetailTitle,
            SourceVocabulary.watchReceivedLabel,
            SourceVocabulary.watchNotYetInJournalLabel,
            SourceVocabulary.watchHandedToJournalLabel,
            SourceVocabulary.watchLastSyncLabel,
            SourceVocabulary.watchLastSyncNever,
            SourceVocabulary.watchActivationLabel,
            SourceVocabulary.watchPairedWithPhoneLabel,
            SourceVocabulary.watchInstalledLabel,
            SourceVocabulary.watchLastReceivedLabel,
            SourceVocabulary.watchLastReceivedNever,
            SourceVocabulary.watchLastStagingDetailLabel,
            SourceVocabulary.watchLastLedgerDetailLabel,
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

    private var emDashCheckedOwnerVisibleStrings: [String] {
        [
            SourceVocabulary.dayLocalityNoJournal,
            SourceVocabulary.connectJournalIntro,
            SourceVocabulary.connectDoorOnYourPhoneTitle,
            SourceVocabulary.connectDoorOnYourPhoneBody,
            SourceVocabulary.connectJournalFloorLine,
            SourceVocabulary.connectJournalHowJournalsWork,
            SourceVocabulary.journalLivesOwnBody,
            SourceVocabulary.journalLivesOnYourPhoneTitle,
            SourceVocabulary.journalLivesOnYourPhoneBody,
            SourceVocabulary.journalLivesCachedLine,
            SourceVocabulary.onThisPhoneEmpty,
            SourceVocabulary.onThisPhoneTruthLine,
            SourceVocabulary.onThisPhoneConnectJournalButton,
            SourceVocabulary.offSubtext(isJournalPaired: false),
            SourceVocabulary.enrollingSubtext(isJournalPaired: false),
            SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: false),
            SourceVocabulary.watchSetupHeader,
            SourceVocabulary.watchSetupValueLine,
            SourceVocabulary.watchSetupNoWatchBody,
            SourceVocabulary.watchCheckingLine,
            SourceVocabulary.watchSetupInstallTitle,
            SourceVocabulary.watchSetupInstallSubline,
            SourceVocabulary.watchSetupInstallButton,
            SourceVocabulary.watchSetupInstallButtonHint,
            SourceVocabulary.watchSetupInstallDisclosureSummary,
            SourceVocabulary.watchSetupInstallDisclosureBody,
            SourceVocabulary.watchSetupOpenTitle,
            SourceVocabulary.watchSetupOpenSubline,
            SourceVocabulary.watchSetupFirstMomentTitle,
            SourceVocabulary.watchSetupCelebration,
            SourceVocabulary.watchSetupStepPending,
            SourceVocabulary.watchSetupStepActive,
            SourceVocabulary.watchSetupStepComplete,
            SourceVocabulary.watchSteadyObservingHeadline,
            SourceVocabulary.watchObservingSentenceBase,
            SourceVocabulary.watchObservingSentence(elapsedMinutes: 2),
            SourceVocabulary.watchSteadyReceivingHeadline,
            SourceVocabulary.watchSteadyWatchWaitingHeadline,
            SourceVocabulary.watchSteadyWatchWaitingSentence(2),
            SourceVocabulary.watchSteadyPhoneSyncingHeadline,
            SourceVocabulary.watchSteadyPhoneSyncingSentence(2),
            SourceVocabulary.watchSteadyCaughtUpSentence,
            SourceVocabulary.watchSteadyQuietHeadline,
            SourceVocabulary.watchPresenceConnectedNow,
            SourceVocabulary.watchPresenceNeverHeard,
            SourceVocabulary.watchPresenceLastHeard(relative: "1m ago"),
            SourceVocabulary.watchTodayHandedLine(2),
            SourceVocabulary.watchSteadyDetailsSummary(watchWaiting: 2, phoneWaiting: 3),
            SourceVocabulary.standingSyncFootnote(sustaining: true),
            SourceVocabulary.standingSyncFootnote(sustaining: false),
            LocationVocabulary.activeSubtext(isJournalPaired: false),
            LocationVocabulary.preEnrollmentValue(isJournalPaired: false),
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
            SourceVocabulary.transferRateLabel,
            SourceVocabulary.transferRateIdle,
            SourceVocabulary.checkConnection,
            SourceVocabulary.probeReachable,
            SourceVocabulary.probeChecked(alive: true, milliseconds: 42, relative: "just now"),
            SourceVocabulary.probeChecked(alive: false, milliseconds: 0, relative: "just now"),
            SourceVocabulary.offSubtext(isJournalPaired: false),
            SourceVocabulary.offSubtext(isJournalPaired: true),
            SourceVocabulary.enrollingSubtext(isJournalPaired: false),
            SourceVocabulary.enrollingSubtext(isJournalPaired: true),
            SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: false),
            SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: true),
            SourceVocabulary.standingSyncFootnote(sustaining: true),
            SourceVocabulary.standingSyncFootnote(sustaining: false),
            SourceVocabulary.dayLocalityNoJournal,
            SourceVocabulary.connectJournalIntro,
            SourceVocabulary.connectDoorOnYourPhoneTitle,
            SourceVocabulary.connectDoorOnYourPhoneBody,
            SourceVocabulary.connectJournalFloorLine,
            SourceVocabulary.connectJournalHowJournalsWork,
            SourceVocabulary.journalLivesOwnBody,
            SourceVocabulary.journalLivesOnYourPhoneTitle,
            SourceVocabulary.journalLivesOnYourPhoneBody,
            SourceVocabulary.journalLivesCachedLine,
            SourceVocabulary.onThisPhoneEmpty,
            SourceVocabulary.onThisPhoneTruthLine,
            SourceVocabulary.onThisPhoneConnectJournalButton,
            SourceVocabulary.migrationHeadlineUpToDate,
            SourceVocabulary.syncingPulse,
            SourceVocabulary.syncedHeadline,
            SourceVocabulary.syncedBody,
            SourceVocabulary.offlineSafeLine,
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
            SourceState.readyToSetUp.label,
            SourceState.checking.label,
            SourceState.active.label,
            SourceState.paused.label,
            SourceState.needsAttention.label,
            SourceVocabulary.offSubtext(isJournalPaired: false),
            SourceVocabulary.offSubtext(isJournalPaired: true),
            SourceVocabulary.enrollingSubtext(isJournalPaired: false),
            SourceVocabulary.enrollingSubtext(isJournalPaired: true),
            SourceVocabulary.pausedSubtext,
            SourceVocabulary.needsAttentionSubtext,
            SourceVocabulary.needsAttention,
            SourceVocabulary.observerActiveSubtext,
            SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: false),
            SourceVocabulary.shareAlwaysOnExplainer(isJournalPaired: true),
            SourceVocabulary.shareSheetDisplayName,
            SourceVocabulary.shareSendingProgress,
            SourceVocabulary.shareDeliveredProgress,
            SourceVocabulary.sendStateSaved,
            SourceVocabulary.sendStateSending,
            SourceVocabulary.sendStateCompactSaved,
            SourceVocabulary.sendStateCompactOnTheWay,
            SourceVocabulary.sendStateCompactInJournal,
            SourceVocabulary.addMoreTitle,
            SourceVocabulary.addMoreSubline,
            SourceVocabulary.importTitle,
            SourceVocabulary.importSubline,
            SourceVocabulary.giveThisATileOnHome,
            SourceVocabulary.hidingThisNeverTurnsItOff,
            SourceVocabulary.whatItAddsTitle,
            SourceVocabulary.openSettings,
            SourceVocabulary.trustLineConfigured,
            SourceVocabulary.recentEmpty,
            SourceVocabulary.recentFailed,
            SourceVocabulary.notConnectedRowAffordance(isJournalPaired: false),
            SourceVocabulary.notConnectedRowAffordance(isJournalPaired: true),
            SourceVocabulary.sourceStateReadyToSetUpLabel,
            SourceVocabulary.sourceStateCheckingLabel,
            SourceVocabulary.watchActivationFailedSubtext,
            SourceVocabulary.watchNoWatchPairedSubtext,
            SourceVocabulary.watchReadyToSetUpSubtext,
            SourceVocabulary.watchInstalledNeverOpenedSubtext,
            SourceVocabulary.watchReceivingNowSubtext,
            SourceVocabulary.watchIdleNowSubtext,
            SourceVocabulary.watchWaitingToSyncFromWatch(2),
            SourceVocabulary.watchSetupHeader,
            SourceVocabulary.watchSetupValueLine,
            SourceVocabulary.watchSetupNoWatchBody,
            SourceVocabulary.watchCheckingLine,
            SourceVocabulary.watchSetupInstallTitle,
            SourceVocabulary.watchSetupInstallSubline,
            SourceVocabulary.watchSetupInstallButton,
            SourceVocabulary.watchSetupInstallButtonHint,
            SourceVocabulary.watchSetupInstallDisclosureSummary,
            SourceVocabulary.watchSetupInstallDisclosureBody,
            SourceVocabulary.watchSetupOpenTitle,
            SourceVocabulary.watchSetupOpenSubline,
            SourceVocabulary.watchSetupFirstMomentTitle,
            SourceVocabulary.watchSetupCelebration,
            SourceVocabulary.watchSetupStepPending,
            SourceVocabulary.watchSetupStepActive,
            SourceVocabulary.watchSetupStepComplete,
            SourceVocabulary.whatItAdds,
            SourceVocabulary.pendingSeam,
            SourceVocabulary.removeSeam,
            SourceVocabulary.importerWhatItAdds,
            SourceVocabulary.onThisPhone,
            SourceVocabulary.dayLocalityNoJournal,
            SourceVocabulary.journalConnected,
            SourceVocabulary.journalOffline,
            SourceVocabulary.onThisPhoneScope,
            SourceVocabulary.onThisPhoneScopeConnected,
            SourceVocabulary.onThisPhoneScopeOfflinePaired,
            SourceVocabulary.onThisPhoneEmpty,
            SourceVocabulary.onThisPhoneTruthLine,
            SourceVocabulary.onThisPhoneConnectJournalButton,
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
            SourceVocabulary.connectDoorOnYourPhoneTitle,
            SourceVocabulary.connectDoorOnYourPhoneBody,
            SourceVocabulary.connectJournalFloorLine,
            SourceVocabulary.connectJournalHowJournalsWork,
            SourceVocabulary.journalLivesTitle,
            SourceVocabulary.journalLivesPromise,
            SourceVocabulary.journalLivesOwnTitle,
            SourceVocabulary.journalLivesOwnBody,
            SourceVocabulary.journalLivesOnYourPhoneTitle,
            SourceVocabulary.journalLivesOnYourPhoneBody,
            SourceVocabulary.journalLivesCachedLine,
            SourceVocabulary.journalLivesComingLater,
            SourceVocabulary.journalLivesConnectAction,
            SourceVocabulary.journalLivesRepairAction,
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
