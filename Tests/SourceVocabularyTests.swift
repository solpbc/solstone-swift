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
        XCTAssertEqual(SourceVocabulary.onThisPhoneDeleteReceipt, "deleted from this phone")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneNotBackedUp,
            "nothing here is backed up yet. connect a journal to keep a copy."
        )
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
        XCTAssertEqual(SourceVocabulary.askEmptyHeadline, "nothing to ask yet")
        XCTAssertEqual(
            SourceVocabulary.askEmptyBody,
            "sol answers from your journal. connect one, and sol can read everything your phone has gathered."
        )
        XCTAssertEqual(SourceVocabulary.askEmptyButton, "connect a journal")
        XCTAssertEqual(SourceVocabulary.askEmptyIconName, "internaldrive")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAgedBacklog(count: 1),
            "1 observation is resting on this phone. connect a journal whenever you'd like a backup."
        )
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneAgedBacklog(count: 12),
            "12 observations are resting on this phone. connect a journal whenever you'd like a backup."
        )
        XCTAssertEqual(SourceVocabulary.askWaitingObservations(count: 1), "1 observation is waiting on this phone.")
        XCTAssertEqual(SourceVocabulary.askWaitingObservations(count: 238), "238 observations are waiting on this phone.")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationRowLabel(count: 1), "1 observation")
        XCTAssertEqual(SourceVocabulary.onThisPhoneLocationRowLabel(count: 12), "12 observations")
        XCTAssertEqual(SourceVocabulary.derivedNotInJournalYet, "not in your journal yet")
        XCTAssertEqual(SourceVocabulary.openJournalInConvey, "open journal ↗")
        XCTAssertEqual(SourceVocabulary.needsAttention, "needs attention")
    }

    func testLockedSourceSubtexts() {
        XCTAssertEqual(SourceVocabulary.offSubtext, "not sending to your journal. turn it on any time.")
        XCTAssertEqual(SourceVocabulary.enrollingSubtext, "getting ready — connecting to your journal.")
        XCTAssertEqual(SourceVocabulary.pausedSubtext, "you paused this. resume to start sending again.")
        XCTAssertEqual(SourceVocabulary.needsAttentionSubtext, "something's not getting through — tap to see what.")
        XCTAssertEqual(SourceVocabulary.importerActiveSubtext, "sending to your journal as you share.")
    }

    func testLockedDeleteCopy() {
        XCTAssertEqual(
            SourceVocabulary.deleteConfirmBody,
            "delete everything share sheet added to your journal? this removes the originals you sent and what sol added from them. other things in your journal stay. this can't be undone."
        )
        XCTAssertEqual(
            SourceVocabulary.deleteConfirmButton,
            "delete share sheet's contributions"
        )
        XCTAssertEqual(
            SourceVocabulary.deleteReceiptHeadlineTemplate,
            "deleted. removed from your journal: {N} items you sent · the originals + a note of where each came from."
        )
        XCTAssertEqual(
            SourceVocabulary.deleteSourceOffLine,
            "share sheet is now off — turn it back on any time."
        )
        XCTAssertEqual(
            SourceVocabulary.deleteJournalUnreachableLine,
            "couldn't reach your journal — nothing was deleted."
        )
    }

    func testDeleteReceiptHeadlineSubstitutesOriginalCount() {
        XCTAssertEqual(
            SourceVocabulary.deleteReceiptHeadline(originals: 7),
            "deleted. removed from your journal: 7 items you sent · the originals + a note of where each came from."
        )
    }

    func testLockedDeleteCopyDoesNotMentionSegments() {
        let strings = [
            SourceVocabulary.deleteConfirmBody,
            SourceVocabulary.deleteConfirmButton,
            SourceVocabulary.deleteReceiptHeadlineTemplate,
            SourceVocabulary.deleteSourceOffLine,
            SourceVocabulary.deleteJournalUnreachableLine,
        ]

        for string in strings {
            XCTAssertFalse(string.contains("segment"))
        }
    }

    func testLockedShareImportCopy() {
        XCTAssertEqual(ShareImportCopy.dismiss, "dismiss")
        XCTAssertEqual(
            ShareImportCopy.failureMessage(plainReason: "{plain reason}"),
            "couldn't save this — {plain reason}. nothing was added."
        )
        XCTAssertEqual(
            ShareImportCopy.connectFirstBody,
            "connect your journal first — then you can send things to it."
        )
        XCTAssertEqual(ShareImportCopy.connectJournalButton, "connect your journal")
        XCTAssertEqual(
            ShareImportCopy.pausedBody,
            "share sheet is paused. resume it to send this, or cancel."
        )
        XCTAssertEqual(ShareImportCopy.cancel, "cancel")
        XCTAssertEqual(ShareImportCopy.resumeAndSend, "resume & send")
        XCTAssertEqual(ShareImportCopy.sendToYourJournal, "send to your journal")
        XCTAssertEqual(
            ShareImportCopy.solCanReadBody,
            "sol can read it so you can find and ask about it later."
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
            SourceVocabulary.onThisPhoneScope,
            SourceVocabulary.onThisPhoneEmpty,
            SourceVocabulary.onThisPhoneDeleteReceipt,
            SourceVocabulary.onThisPhoneNotBackedUp,
            SourceVocabulary.migrationStageOnThisPhone,
            SourceVocabulary.migrationStageOnItsWay,
            SourceVocabulary.migrationStageInYourJournal,
            SourceVocabulary.migrationReached(count: 2),
            SourceVocabulary.migrationStageCount(2, stage: SourceVocabulary.migrationStageOnItsWay),
            SourceVocabulary.onThisPhoneAgedBacklog(count: 2),
            SourceVocabulary.onThisPhoneLocationRowLabel(count: 2),
            SourceVocabulary.yourJournalSection,
            SourceVocabulary.onThisPhoneSource,
            SourceVocabulary.onThisPhonePlacement,
            SourceVocabulary.failedImportSubtext,
            SourceVocabulary.notProvided,
            SourceVocabulary.originAppNotProvided,
            SourceVocabulary.rawOriginalUnavailable,
            SourceVocabulary.derivedNotInJournalYet,
            SourceVocabulary.openJournalInConvey,
            SourceVocabulary.filenameLabel,
            SourceVocabulary.originAppLabel,
            SourceVocabulary.sendStateLabel,
            SourceVocabulary.deliveredAtLabel,
            SourceVocabulary.connectJournalIntro,
            SourceVocabulary.connectDoorOwnTitle,
            SourceVocabulary.connectDoorOwnSubtitle,
            SourceVocabulary.connectDoorHostedTitle,
            SourceVocabulary.connectDoorHostedSubtitle,
            SourceVocabulary.retry,
            SourceVocabulary.drop,
            SourceVocabulary.turnOn,
            SourceVocabulary.pause,
            SourceVocabulary.resume,
            SourceVocabulary.delete,
            SourceVocabulary.deleteConfirmBody,
            SourceVocabulary.deleteConfirmButton,
            SourceVocabulary.deleteReceiptHeadlineTemplate,
            SourceVocabulary.deleteSourceOffLine,
            SourceVocabulary.deleteJournalUnreachableLine,
            ShareImportCopy.dismiss,
            ShareImportCopy.connectFirstBody,
            ShareImportCopy.connectJournalButton,
            ShareImportCopy.pausedBody,
            ShareImportCopy.cancel,
            ShareImportCopy.resumeAndSend,
            ShareImportCopy.sendToYourJournal,
            ShareImportCopy.solCanReadBody,
        ]
    }
}
