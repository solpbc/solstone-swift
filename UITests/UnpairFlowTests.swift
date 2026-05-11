// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class UnpairFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testUnpairReturnsToOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]

        let journalRoot = ProcessInfo.processInfo.environment["UI_TEST_JOURNAL_ROOT"] ?? "http://127.0.0.1:8676"
        let sessionKey = ProcessInfo.processInfo.environment["UI_TEST_PAIR_SESSION"] ?? "pair-session-test"
        let deviceID = ProcessInfo.processInfo.environment["UI_TEST_DEVICE_ID"] ?? "device-123"
        app.launchArguments.append("--ui-test-journal-root=\(journalRoot)")
        app.launchArguments.append("--ui-test-pair-session=\(sessionKey)")
        app.launchArguments.append("--ui-test-device-id=\(deviceID)")

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        app.tabBars.buttons["more"].tap()

        let unpairButton = app.buttons["unpair this device"]
        self.scrollToElement(unpairButton, in: app)
        XCTAssertTrue(unpairButton.waitForExistence(timeout: 5))
        unpairButton.tap()

        let confirmButton = app.alerts.buttons["Unpair"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertTrue(app.buttons["get started"].waitForExistence(timeout: 10))
    }
}


@MainActor
private extension UnpairFlowTests {
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
    }
}
