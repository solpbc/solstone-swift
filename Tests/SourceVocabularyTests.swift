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
        XCTAssertEqual(SourceVocabulary.details, "details")
        XCTAssertEqual(SourceVocabulary.dayHomeAskBarHint, "connect a journal to ask sol")
        XCTAssertEqual(SourceVocabulary.journalConnected, "your journal · connected")
        XCTAssertEqual(SourceVocabulary.journalOffline, "your journal · offline")
        XCTAssertEqual(SourceVocabulary.yourSolstoneTitle, "your solstone")
        XCTAssertEqual(SourceVocabulary.openInJournal, "open in journal")
        XCTAssertEqual(SourceVocabulary.askBarOffline, "journal offline")
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
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneScope,
            "everything your observers have gathered, resting here until you connect a journal."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneEmpty,
            "nothing here yet. turn on a source and solstone starts observing alongside you — kept right here."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneNotBackedUp,
            "nothing here is backed up yet. connect a journal to keep a copy."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneTurnOnSourceButton, "turn on a source")
        XCTAssertEqual(SourceVocabulary.migrationStageOnThisPhone, "on this phone")
        XCTAssertEqual(SourceVocabulary.migrationStageOnItsWay, "on its way")
        XCTAssertEqual(SourceVocabulary.migrationStageInYourJournal, "your journal")
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
        XCTAssertEqual(SourceVocabulary.openJournalInConvey, "open journal ↗")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneLocationC3Hint,
            "the map of where your day happened lives in your journal — this screen just confirms what your phone sensed. no live dot, nothing tracked here."
        )
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
            SourceVocabulary.onThisPhoneDropConfirmMessage(noun: "this audio"),
            "removes this audio from this phone. if it already reached your journal, the journal keeps its copy. this part can't be undone once it commits."
        )
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropAudioNoun, "this audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropLocationNoun, "these places")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropShareNoun, "this file")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropSnackbar(descriptor: "1m 15s of audio"), "dropped “1m 15s of audio”.")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropAudioDescriptor(duration: "1m 15s"), "1m 15s of audio")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropLocationDescriptor(count: 2), "2 observations")
        XCTAssertEqual(SourceVocabulary.onThisPhoneFileLabel, "file")
        XCTAssertEqual(SourceVocabulary.onThisPhoneWhenLabel, "when")
        XCTAssertEqual(SourceVocabulary.onThisPhoneObservationsLabel, "observations")
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
    }

    func testLockedSourceSubtexts() {
        XCTAssertEqual(SourceVocabulary.offSubtext, "not sending to your journal. turn it on any time.")
        XCTAssertEqual(SourceVocabulary.enrollingSubtext, "getting ready — connecting to your journal.")
        XCTAssertEqual(SourceVocabulary.pausedSubtext, "you paused this. resume to start sending again.")
        XCTAssertEqual(SourceVocabulary.needsAttentionSubtext, "something's not getting through — tap to see what.")
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
            SourceVocabulary.dayLocality,
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
            SourceVocabulary.onThisPhoneEmpty,
            SourceVocabulary.onThisPhoneNotBackedUp,
            SourceVocabulary.onThisPhoneTurnOnSourceButton,
            SourceVocabulary.migrationStageOnThisPhone,
            SourceVocabulary.migrationStageOnItsWay,
            SourceVocabulary.migrationStageInYourJournal,
            SourceVocabulary.migrationReached(count: 2),
            SourceVocabulary.migrationStageCount(2, stage: SourceVocabulary.migrationStageOnItsWay),
            SourceVocabulary.onThisPhoneAgedBacklog(count: 2),
            SourceVocabulary.onThisPhoneLocationRowLabel(count: 2),
            SourceVocabulary.yourJournalSection,
            SourceVocabulary.details,
            SourceVocabulary.notProvided,
            SourceVocabulary.originAppNotProvided,
            SourceVocabulary.rawOriginalUnavailable,
            SourceVocabulary.openJournalInConvey,
            SourceVocabulary.openInJournal,
            SourceVocabulary.onThisPhoneLocationC3Hint,
            SourceVocabulary.onThisPhoneJournalHintSaved,
            SourceVocabulary.onThisPhoneJournalHintLocationSaved,
            SourceVocabulary.onThisPhoneJournalHintPending,
            SourceVocabulary.onThisPhoneJournalHintUnreachable,
            SourceVocabulary.onThisPhoneJournalHintLocationUnreachable,
            SourceVocabulary.onThisPhoneDropFromPhone,
            SourceVocabulary.onThisPhoneDropConfirmTitle,
            SourceVocabulary.onThisPhoneDropConfirmMessage(noun: SourceVocabulary.onThisPhoneDropAudioNoun),
            SourceVocabulary.onThisPhoneDropAudioNoun,
            SourceVocabulary.onThisPhoneDropLocationNoun,
            SourceVocabulary.onThisPhoneDropShareNoun,
            SourceVocabulary.onThisPhoneDropSnackbar(descriptor: "1m 15s of audio"),
            SourceVocabulary.onThisPhoneDropAudioDescriptor(duration: "1m 15s"),
            SourceVocabulary.onThisPhoneDropLocationDescriptor(count: 2),
            SourceVocabulary.onThisPhoneFileLabel,
            SourceVocabulary.onThisPhoneWhenLabel,
            SourceVocabulary.onThisPhoneObservationsLabel,
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
            SourceVocabulary.retry,
            SourceVocabulary.drop,
            SourceVocabulary.cancel,
            SourceVocabulary.undo,
            SourceVocabulary.turnOn,
            SourceVocabulary.pause,
            SourceVocabulary.resume,
            SourceVocabulary.delete,
            SourceVocabulary.deleteJournalUnreachableLine,
            ShareImportCopy.dismiss,
            ShareImportCopy.savedAccessibilityLabel,
        ]
    }
}
