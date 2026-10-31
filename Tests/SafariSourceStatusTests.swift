// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class SafariSourceStatusTests: XCTestCase {
    private func snapshot(contact: Bool = true, paused: Bool = false, full: Bool = false, confirmed: Bool = true) -> SafariBrowserSnapshot {
        SafariBrowserSnapshot(confirmed: confirmed, paused: paused, heldBytes: 0, queuedBytes: 0, lastAccepted: nil,
            lastContact: contact ? Date() : nil, full: full)
    }

    func testTheSourceIsReadyToSetUpUntilSafarisExtensionAnswers() {
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot(contact: false)).sourceState, .readyToSetUp)
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot()).sourceState, .active)
    }

    func testPauseAndAFullStoreShowAsTheirOwnStates() {
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot(paused: true)).sourceState, .paused)
        let full = SafariSourceStatus(snapshot: self.snapshot(full: true))
        XCTAssertEqual(full.sourceState, .needsAttention)
        XCTAssertEqual(full.attention, SafariVocabulary.full)
        XCTAssertEqual(SafariSourceStatus(snapshot: nil).sourceState, .needsAttention)
    }

    func testWithoutAConfirmedJournalTheSourceIsOffAndSaysWhy() {
        let awaiting = safariSourceModel(snapshot: self.snapshot(confirmed: false), isJournalPaired: true)
        XCTAssertEqual(awaiting.state, .off)
        XCTAssertEqual(awaiting.subtext, SafariVocabulary.awaitingMark)
        let unpaired = safariSourceModel(snapshot: self.snapshot(confirmed: false), isJournalPaired: false)
        XCTAssertEqual(unpaired.subtext, SafariVocabulary.notPaired)
    }
}
