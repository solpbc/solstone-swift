// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class SourceVocabularyTests: XCTestCase {
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
}
