// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class PaneHostUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testHitStripExistsOnlyOnRoot() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))

        let strip = app.descendants(matching: .any)["shell.hitStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))

        let audio = app.buttons["dayHome.tile.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.tap()
        XCTAssertTrue(app.navigationBars["audio"].waitForExistence(timeout: 5))
        XCTAssertFalse(strip.exists)

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
    }

    @MainActor
    func testStatusPushOpensDiagnostics() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=status"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let pane = app.descendants(matching: .any)["shell.pane.status"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 5))
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let mediumValue = grabber.value as? String

        let diagnostics = app.descendants(matching: .any)["shell.pane.status.diagnostics"]
        self.scrollToElement(diagnostics, in: app)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.lifecycle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["diagnostics"].waitForExistence(timeout: 5))
        XCTAssertEqual(grabber.value as? String, "Expanded")

        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["diagnostics"].exists)
        XCTAssertNotEqual(grabber.value as? String, "Expanded")
        XCTAssertEqual(grabber.value as? String, mediumValue)

        let reports = app.descendants(matching: .any)["shell.pane.status.problemReports"]
        self.scrollToElement(reports, in: app)
        XCTAssertTrue(reports.waitForExistence(timeout: 5))
        reports.tap()
        XCTAssertTrue(
            app.otherElements["problemReports.empty.optedOut"].waitForExistence(timeout: 10)
                || app.navigationBars["problem reports"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(grabber.value as? String, "Expanded")
    }

    @MainActor
    func testStatusDegradedWhenDisconnected() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-shell-disconnected",
            "--ui-test-open-pane=status",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let degraded = app.descendants(matching: .any)["shell.pane.status.degraded"]
        XCTAssertTrue(degraded.waitForExistence(timeout: 10))
        XCTAssertTrue(degraded.label.contains("offline") || (degraded.value as? String)?.contains("offline") == true)
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.connected"].exists)
        XCTAssertNotEqual(degraded.label, "0")
        XCTAssertNotEqual(degraded.value as? String, "0")
    }

    @MainActor
    func testStatusConnectedTwinWhenUp() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=status"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let connected = app.descendants(matching: .any)["shell.pane.status.connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.degraded"].exists)
        let value = (connected.value as? String) ?? connected.label
        XCTAssertTrue(
            value.contains("connected"),
            value
        )
        XCTAssertNotEqual(value, "0")
    }
}

@MainActor
private extension PaneHostUITests {
    func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 2) {
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
            if element.waitForExistence(timeout: 1) {
                return
            }
        }
    }
}
