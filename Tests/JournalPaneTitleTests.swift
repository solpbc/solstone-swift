// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class JournalPaneTitleTests: XCTestCase {
    func testNilMarkEmptyPageTitleUsesPlaceholderNotJournal() {
        let title = journalPaneTitle(mark: nil, pageTitle: "")
        XCTAssertNotEqual(title, "journal")
        XCTAssertTrue(title.hasPrefix("dev-copy:"))
    }

    func testNilMarkUsesNonEmptyPageTitle() {
        XCTAssertEqual(journalPaneTitle(mark: nil, pageTitle: "  morning notes  "), "morning notes")
    }

#if DEBUG
    func testPresentMarkUsesJoinedWords() {
        XCTAssertEqual(journalPaneTitle(mark: .uiTestSample, pageTitle: "ignored"), "afoot · unfixed")
    }
#endif
}
