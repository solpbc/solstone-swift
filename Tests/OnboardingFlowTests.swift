// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnboardingFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        self.suiteName = "OnboardingFlowTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testFlowTransitionsToDone() {
        let flow = OnboardingFlow(defaults: self.defaults)

        flow.advanceFromWelcome()
        XCTAssertEqual(flow.step, .firstSource)

        flow.completeFirstSource(choseSource: true)
        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isCompleted)
        XCTAssertTrue(flow.choseFirstSource)
    }

    @MainActor
    func testCompleteViaPairingPersistsCompletedDoneWithoutFirstSource() {
        let flow = OnboardingFlow(defaults: self.defaults)

        flow.completeViaPairing()

        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isCompleted)
        XCTAssertFalse(flow.choseFirstSource)

        let restored = OnboardingFlow(defaults: self.defaults)
        XCTAssertTrue(restored.isCompleted)
        XCTAssertEqual(restored.step, .done)
    }

    @MainActor
    func testGoBackFromFirstSourceReturnsToWelcome() {
        let flow = OnboardingFlow(defaults: self.defaults)

        flow.advanceFromWelcome()
        flow.goBack()

        XCTAssertEqual(flow.step, .welcome)
        XCTAssertFalse(flow.isCompleted)
    }

    @MainActor
    func testRestoreMigratesPairToWelcomeAndPersists() {
        self.defaults.set("pair", forKey: "onboarding.step")
        self.defaults.set(false, forKey: "onboarding.completed")

        let flow = OnboardingFlow(defaults: self.defaults)

        XCTAssertEqual(flow.step, .welcome)
        XCTAssertFalse(flow.isCompleted)
        XCTAssertEqual(self.defaults.string(forKey: "onboarding.step"), "welcome")
        XCTAssertFalse(self.defaults.bool(forKey: "onboarding.completed"))
    }

    @MainActor
    func testRestoreMigratesNotificationsToCompletedDoneAndPersists() {
        self.defaults.set("notifications", forKey: "onboarding.step")
        self.defaults.set(false, forKey: "onboarding.completed")

        let flow = OnboardingFlow(defaults: self.defaults)

        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isCompleted)
        XCTAssertEqual(self.defaults.string(forKey: "onboarding.step"), "done")
        XCTAssertTrue(self.defaults.bool(forKey: "onboarding.completed"))
    }

    @MainActor
    func testRestoreMigratesBriefingTimeToCompletedDoneAndPersists() {
        self.defaults.set("briefing_time", forKey: "onboarding.step")
        self.defaults.set(false, forKey: "onboarding.completed")

        let flow = OnboardingFlow(defaults: self.defaults)

        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isCompleted)
        XCTAssertEqual(self.defaults.string(forKey: "onboarding.step"), "done")
        XCTAssertTrue(self.defaults.bool(forKey: "onboarding.completed"))
    }

    @MainActor
    func testCompletedRestoreWinsOverStep() {
        self.defaults.set("welcome", forKey: "onboarding.step")
        self.defaults.set(true, forKey: "onboarding.completed")

        let flow = OnboardingFlow(defaults: self.defaults)

        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isCompleted)
    }

    @MainActor
    func testConnectCompletionClosureDoesNotMutateOnboardingFlow() {
        let flow = OnboardingFlow(defaults: self.defaults)
        flow.advanceFromWelcome()
        let stepBefore = flow.step
        let isCompletedBefore = flow.isCompleted
        var didDismiss = false

        let onComplete = {
            didDismiss = true
        }
        onComplete()

        XCTAssertTrue(didDismiss)
        XCTAssertEqual(flow.step, stepBefore)
        XCTAssertEqual(flow.isCompleted, isCompletedBefore)
    }
}
