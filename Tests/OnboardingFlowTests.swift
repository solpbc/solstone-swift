// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OnboardingFlowTests: XCTestCase {
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

    func testFlowTransitionsToDone() {
        let flow = OnboardingFlow(defaults: self.defaults)

        flow.advanceFromWelcome()
        XCTAssertEqual(flow.step, .pair)

        flow.completePairing()
        XCTAssertEqual(flow.step, .notifications)

        flow.completeNotifications(granted: true)
        XCTAssertEqual(flow.step, .briefingTime)
        XCTAssertEqual(flow.notificationsGranted, true)

        flow.completeBriefingTime()
        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isCompleted)
    }

    func testFlowRestoreReadsPersistedState() {
        self.defaults.set("notifications", forKey: "onboarding.step")
        self.defaults.set(false, forKey: "onboarding.completed")

        let flow = OnboardingFlow(defaults: self.defaults)

        XCTAssertEqual(flow.step, .notifications)
        XCTAssertFalse(flow.isCompleted)
    }

    func testCompletedRestoreWinsOverStep() {
        self.defaults.set("pair", forKey: "onboarding.step")
        self.defaults.set(true, forKey: "onboarding.completed")

        let flow = OnboardingFlow(defaults: self.defaults)

        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isCompleted)
    }
}
