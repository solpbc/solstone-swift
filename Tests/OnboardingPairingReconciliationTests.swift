// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnboardingPairingReconciliationTests: XCTestCase {
    func testCompletesWhenPairedAndOnboardingIncomplete() {
        XCTAssertTrue(
            OnboardingPairingReconciliation.shouldComplete(isPaired: true, isOnboardingCompleted: false)
        )
    }

    func testDoesNotCompleteWhenPairedAndOnboardingCompleted() {
        XCTAssertFalse(
            OnboardingPairingReconciliation.shouldComplete(isPaired: true, isOnboardingCompleted: true)
        )
    }

    func testDoesNotCompleteWhenUnpairedAndOnboardingIncomplete() {
        XCTAssertFalse(
            OnboardingPairingReconciliation.shouldComplete(isPaired: false, isOnboardingCompleted: false)
        )
    }

    func testDoesNotCompleteWhenUnpairedAndOnboardingCompleted() {
        XCTAssertFalse(
            OnboardingPairingReconciliation.shouldComplete(isPaired: false, isOnboardingCompleted: true)
        )
    }
}
