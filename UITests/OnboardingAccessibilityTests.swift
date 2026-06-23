// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class OnboardingAccessibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeAndFirstSourceScreensExposeAccessibilityMetadata() {
        self.assertWelcomeAndFirstSourceScreens()
    }

    @MainActor
    func testFirstSourceSeedExposesAccessibilityMetadata() {
        self.assertFirstSourceSeed()
    }

    @MainActor
    func testMoreViewExposesAccessibilityMetadata() {
        self.assertMoreViewAccessibility()
    }
}


@MainActor
private extension OnboardingAccessibilityTests {
    func assertWelcomeAndFirstSourceScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-onboarding-step=welcome"]
        app.launch()

        let getStarted = app.buttons["get started"]
        self.assertMetadata(for: getStarted, in: app)
        getStarted.tap()

        self.assertMetadata(for: app.staticTexts["start with a source"], in: app)
        self.assertMetadata(for: app.buttons["onboarding.firstSource.audio"], in: app)
        self.assertMetadata(for: app.buttons["onboarding.firstSource.location"], in: app)
        self.assertMetadata(for: app.buttons["look around first"], in: app)
        self.assertMetadata(for: app.buttons["back"], in: app)
    }

    func assertFirstSourceSeed() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-onboarding-step=first_source",
        ]
        app.launch()

        self.assertMetadata(for: app.staticTexts["start with a source"], in: app)
        self.assertMetadata(for: app.buttons["look around first"], in: app)
        self.assertMetadata(for: app.buttons["back"], in: app)
    }

    func assertMoreViewAccessibility() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()

        app.buttons["dayHome.yourSolstoneEntry"].tap()
        XCTAssertTrue(app.navigationBars["your solstone"].waitForExistence(timeout: 10))

        self.scrollToElement(app.buttons["enable notifications"], in: app)
        self.assertMetadata(for: app.buttons["enable notifications"], in: app)
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
        if element.waitForExistence(timeout: 5) {
            return
        }
        let scrollContainer = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.scrollViews.firstMatch
        XCTAssertTrue(scrollContainer.waitForExistence(timeout: 10))

        let start = scrollContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let end = scrollContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        for _ in 1...10 {
            start.press(forDuration: 0.05, thenDragTo: end)
            if element.waitForExistence(timeout: 2) {
                return
            }
        }
        XCTFail("Element did not appear after scrolling: \(element)")
    }
}
