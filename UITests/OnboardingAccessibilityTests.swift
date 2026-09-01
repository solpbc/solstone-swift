// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class OnboardingAccessibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeScreenExposesAccessibilityMetadata() {
        self.assertWelcomeScreen()
    }

    @MainActor
    func testShelfExposesAccessibilityMetadata() throws {
        try self.assertShelfAccessibility()
    }
}


@MainActor
private extension OnboardingAccessibilityTests {
    func assertWelcomeScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-onboarding-step=welcome"]
        app.launch()

        let getStarted = app.buttons["get started"]
        self.assertMetadata(for: getStarted, in: app)
    }

    func assertShelfAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")

        app.buttons["dayHome.yourSolstoneEntry"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 5))

        let notifications = app.descendants(matching: .any)["shell.pane.shelf.notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        notifications.tap()
        self.scrollToElement(app.buttons["enable notifications"], in: app)
        self.assertMetadata(for: app.buttons["enable notifications"], in: app)
        // ⚠ Scoped to the shelf's own bar. `app.navigationBars.buttons.firstMatch` used
        // to be unambiguous only because the shell behind the drawer was not rendering
        // at all; now that it is, the first navigation bar in the tree is the DECK's and
        // its first button is the shelf control — so the "back" tap closed the drawer
        // instead of popping the pane.
        app.descendants(matching: .any)["shell.pane.shelf"]
            .navigationBars.buttons.firstMatch.tap()

        let thisDevice = app.descendants(matching: .any)["shell.pane.shelf.thisDevice"]
        XCTAssertTrue(thisDevice.waitForExistence(timeout: 5))
        thisDevice.tap()
        self.scrollToElement(app.switches["haptics"], in: app)
        self.assertMetadata(for: app.switches["haptics"], in: app)
        self.scrollToElement(app.buttons["unpair this device"], in: app)
        self.assertMetadata(for: app.buttons["unpair this device"], in: app)
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
