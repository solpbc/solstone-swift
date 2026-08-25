// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class JournalPaneTitleTests: XCTestCase {
    func testNilMarkUsesPlaceholderWords() {
        XCTAssertEqual(journalPaneTitle(mark: nil), "your · journal")
    }

#if DEBUG
    func testPresentMarkUsesJoinedWords() {
        XCTAssertEqual(journalPaneTitle(mark: .uiTestSample), "afoot · unfixed")
    }
#endif
}
