// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnboardingPairingReconciliationTests: XCTestCase {
    func testCompletesWhenPairedConfirmedAndOnboardingIncomplete() {
        XCTAssertTrue(
            OnboardingPairingReconciliation.shouldComplete(
                isPaired: true,
                journalSendConfirmed: true,
                isOnboardingCompleted: false
            )
        )
    }

    func testDoesNotCompleteWhenPairedUnconfirmedAndOnboardingIncomplete() {
        XCTAssertFalse(
            OnboardingPairingReconciliation.shouldComplete(
                isPaired: true,
                journalSendConfirmed: false,
                isOnboardingCompleted: false
            )
        )
    }

    func testDoesNotCompleteWhenPairedConfirmedAndOnboardingCompleted() {
        XCTAssertFalse(
            OnboardingPairingReconciliation.shouldComplete(
                isPaired: true,
                journalSendConfirmed: true,
                isOnboardingCompleted: true
            )
        )
    }

    func testDoesNotCompleteWhenUnpairedAndOnboardingIncomplete() {
        XCTAssertFalse(
            OnboardingPairingReconciliation.shouldComplete(
                isPaired: false,
                journalSendConfirmed: false,
                isOnboardingCompleted: false
            )
        )
    }

    func testDoesNotCompleteWhenUnpairedAndOnboardingCompleted() {
        XCTAssertFalse(
            OnboardingPairingReconciliation.shouldComplete(
                isPaired: false,
                journalSendConfirmed: false,
                isOnboardingCompleted: true
            )
        )
    }
}
