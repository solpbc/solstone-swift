// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class JournalIdentityTests: XCTestCase {
#if DEBUG
    func testSelectReturnsGenericWhenUnpairedOrUnconfirmed() {
        XCTAssertEqual(
            JournalIdentity.select(isPaired: false, sendConfirmed: true, mark: .uiTestSample),
            .generic
        )
        XCTAssertEqual(
            JournalIdentity.select(isPaired: true, sendConfirmed: false, mark: .uiTestSample),
            .awaitingConfirmation
        )
        XCTAssertEqual(
            JournalIdentity.select(isPaired: false, sendConfirmed: false, mark: nil),
            .generic
        )
    }

    func testAwaitingConfirmationSpeaksForItselfAndReadsAsTheGenericMark() {
        XCTAssertNotEqual(JournalIdentity.awaitingConfirmation.spokenValue, JournalIdentity.generic.spokenValue)
        XCTAssertEqual(JournalIdentity.awaitingConfirmation.spokenValue, JournalMarkGeneric.awaitingConfirmationSpokenValue)
        XCTAssertEqual(JournalIdentity.awaitingConfirmation.title, JournalIdentity.generic.title)
        XCTAssertEqual(JournalIdentity.awaitingConfirmation.words, JournalIdentity.generic.words)
    }

    func testWordsAreTheOnesTheTitleJoins() {
        for identity in [JournalIdentity.mark(.uiTestSample), .generic, .awaitingConfirmation, .unavailable] {
            XCTAssertEqual(identity.words.joined(separator: " · "), identity.title)
        }
    }

    func testSelectReturnsMarkWhenPairedConfirmedAndValid() {
        XCTAssertEqual(
            JournalIdentity.select(isPaired: true, sendConfirmed: true, mark: .uiTestSample),
            .mark(.uiTestSample)
        )
    }

    func testSelectReturnsUnavailableWhenConfirmedWithNilMark() {
        XCTAssertEqual(
            JournalIdentity.select(isPaired: true, sendConfirmed: true, mark: nil),
            .unavailable
        )
    }

    func testSelectReturnsUnavailableWhenConfirmedWithInvalidMark() {
        let oneWordMark = JournalMark(
            icon1: JournalMark.uiTestSample.icon1,
            icon2: JournalMark.uiTestSample.icon2,
            words: ["only"]
        )
        XCTAssertEqual(
            JournalIdentity.select(isPaired: true, sendConfirmed: true, mark: oneWordMark),
            .unavailable
        )

        let emptyWordMark = JournalMark(
            icon1: JournalMark.uiTestSample.icon1,
            icon2: JournalMark.uiTestSample.icon2,
            words: ["", "unfixed"]
        )
        XCTAssertEqual(
            JournalIdentity.select(isPaired: true, sendConfirmed: true, mark: emptyWordMark),
            .unavailable
        )
    }
#endif
}
