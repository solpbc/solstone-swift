// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

final class OnboardingAccessibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWelcomeAndPairScreenExposeAccessibilityMetadata() {
        self.assertWelcomeAndPairScreen()
    }

    func testNotificationsScreenExposesAccessibilityMetadata() {
        self.assertNotificationsScreen()
    }

    func testBriefingTimeScreenExposesAccessibilityMetadata() {
        self.assertBriefingTimeScreen()
    }

    func testMoreViewExposesAccessibilityMetadata() {
        self.assertMoreViewAccessibility()
    }
}

private extension OnboardingAccessibilityTests {
    func assertWelcomeAndPairScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-onboarding-step=welcome"]
        app.launch()

        let getStarted = app.buttons["Get started"]
        self.assertMetadata(for: getStarted, in: app)
        getStarted.tap()

        self.assertMetadata(for: app.buttons["Scan pairing code"], in: app)
        self.assertMetadata(for: app.textFields["Pairing URL"], in: app)
        self.assertMetadata(for: app.buttons["Pair this device"], in: app)
        self.assertMetadata(for: app.buttons["Back"], in: app)
    }

    func assertNotificationsScreen() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-onboarding-step=notifications",
            "--ui-test-pair-session=pair-session-test",
        ]
        app.launch()

        self.assertMetadata(for: app.buttons["Allow notifications"], in: app)
        self.assertMetadata(for: app.buttons["Skip for now"], in: app)
        self.assertMetadata(for: app.buttons["Back"], in: app)
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
        self.assertMetadata(for: app.buttons["Get started"], in: app)
        self.assertMetadata(for: app.buttons["Use 7:00 AM"], in: app)
        self.assertMetadata(for: app.buttons["Back"], in: app)
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
