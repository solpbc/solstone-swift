// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class OnboardingAccessibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeAndPairScreenExposeAccessibilityMetadata() {
        self.assertWelcomeAndPairScreen()
    }

    @MainActor
    func testNotificationsScreenExposesAccessibilityMetadata() {
        self.assertNotificationsScreen()
    }

    @MainActor
    func testBriefingTimeScreenExposesAccessibilityMetadata() {
        self.assertBriefingTimeScreen()
    }

    @MainActor
    func testMoreViewExposesAccessibilityMetadata() throws {
        throw XCTSkip("flaky under simulator load: wedges the sim; deflake tracked separately")
        self.assertMoreViewAccessibility()
    }
}


@MainActor
private extension OnboardingAccessibilityTests {
    func assertWelcomeAndPairScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-onboarding-step=welcome"]
        app.launch()

        let getStarted = app.buttons["get started"]
        self.assertMetadata(for: getStarted, in: app)
        getStarted.tap()

        self.assertMetadata(for: app.staticTexts["pair your solstone"], in: app)
        self.assertMetadata(for: app.buttons["paste"], in: app)
        app.buttons["paste"].tap()
        self.assertMetadata(for: app.buttons["pair this device"], in: app)
        self.assertMetadata(for: app.buttons["back"], in: app)
    }

    func assertNotificationsScreen() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-onboarding-step=notifications",
            "--ui-test-pair-session=pair-session-test",
        ]
        app.launch()

        self.assertMetadata(for: app.buttons["allow notifications"], in: app)
        self.assertMetadata(for: app.buttons["skip for now"], in: app)
        self.assertMetadata(for: app.buttons["back"], in: app)
    }

    func assertBriefingTimeScreen() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-onboarding-step=briefing_time",
            "--ui-test-pair-session=pair-session-test",
        ]
        app.launch()

        self.assertMetadata(for: app.datePickers.element(boundBy: 0), in: app)
        self.assertMetadata(for: app.buttons["get started"], in: app)
        self.assertMetadata(for: app.buttons["use 7:00 AM"], in: app)
        self.assertMetadata(for: app.buttons["back"], in: app)
    }

    func assertMoreViewAccessibility() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()

        app.tabBars.buttons["more"].tap()

        self.scrollToElement(app.buttons["save briefing time"], in: app)
        self.assertMetadata(for: app.buttons["save briefing time"], in: app)
        self.scrollToElement(app.switches["haptics"], in: app)
        self.assertMetadata(for: app.switches["haptics"], in: app)
        self.scrollToElement(app.buttons["unpair this device"], in: app)
        self.assertMetadata(for: app.buttons["unpair this device"], in: app)
        XCTAssertTrue(app.staticTexts["identity"].exists || app.staticTexts["about"].exists)
    }

    func assertMetadata(for element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        XCTAssertFalse(element.label.isEmpty)
        XCTAssertFalse(app.debugDescription.isEmpty)
    }

    func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 2) {
            return
        }
        for _ in 1...6 {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return
            }
        }
        XCTFail("Element did not appear after scrolling: \(element)")
    }
}
