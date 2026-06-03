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
        XCTAssertEqual(SourceVocabulary.trustLine, "feeds only your journal — nowhere else")
        XCTAssertEqual(SourceVocabulary.shareSendingProgress, "sending to your journal…")
        XCTAssertEqual(SourceVocabulary.shareDeliveredProgress, "saved to your journal")
        XCTAssertEqual(SourceVocabulary.journalDashboardTitle, "journal dashboard")
        XCTAssertEqual(SourceVocabulary.yourJournalSection, "your journal")
        XCTAssertEqual(
            SourceVocabulary.onThisPhoneEmpty,
            "nothing here yet. things you send to your journal show up here so you can check they arrived."
        )
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
            "in your journal",
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
            SourceVocabulary.experiencingAlongsideYouHeader,
            SourceVocabulary.bringingInYourselfHeader,
            SourceVocabulary.trustLine,
            SourceVocabulary.recentEmpty,
            SourceVocabulary.recentFailed,
            SourceVocabulary.notConnectedRowAffordance,
            SourceVocabulary.notConnectedDetailHelper,
            SourceVocabulary.zeroActiveSummary,
            SourceVocabulary.whatItAdds,
            SourceVocabulary.pendingSeam,
            SourceVocabulary.removeSeam,
            SourceVocabulary.importerWhatItAdds,
            SourceVocabulary.onThisPhone,
            SourceVocabulary.onThisPhoneScope,
            SourceVocabulary.onThisPhoneEmpty,
            SourceVocabulary.onThisPhoneFailed,
            SourceVocabulary.journalDashboardTitle,
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
