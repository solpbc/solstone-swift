// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OnThisPhoneRowTests: XCTestCase {
    func testShouldShowChipOnlyForNeedsAttentionAndDeliveredStates() {
        XCTAssertTrue(shouldShowChip(.needsAttention))
        XCTAssertTrue(shouldShowChip(.inYourJournal))
        XCTAssertFalse(shouldShowChip(.savedOnThisPhone))
        XCTAssertFalse(shouldShowChip(.sending))
    }
}
