// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class ConnectionStallUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testStalledPaneWithScreenBacklog() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-stall=stalled",
            "--ui-test-open-pane=status",
            "--ui-test-seed-screen-backlog",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let pillProbe = app.descendants(matching: .any)["dayHome.statusPill.state.stalled"]
        XCTAssertTrue(pillProbe.waitForExistence(timeout: 10))

        let leadProbe = app.descendants(matching: .any)["shell.pane.status.leadState.stalled"]
        XCTAssertTrue(leadProbe.waitForExistence(timeout: 10))

        let reason = app.descendants(matching: .any)["shell.pane.status.stall.reason"]
        let tryAgain = app.descendants(matching: .any)["shell.pane.status.stall.tryAgain"]
        let pairAgain = app.descendants(matching: .any)["shell.pane.status.stall.pairAgain"]

        self.scrollToElement(reason, in: app)
        XCTAssertTrue(reason.exists)
        self.scrollToElement(tryAgain, in: app)
        XCTAssertTrue(tryAgain.exists)
        self.scrollToElement(pairAgain, in: app)
        XCTAssertTrue(pairAgain.exists)

        XCTAssertLessThan(reason.frame.minY, tryAgain.frame.minY)
        XCTAssertLessThan(tryAgain.frame.minY, pairAgain.frame.minY)

        XCTAssertTrue(tryAgain.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.degraded"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.checkConnection"].exists)
    }

    @MainActor
    func testStalledConnectedPaneWithScreenBacklog() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-stall=stalled-connected",
            "--ui-test-open-pane=status",
            "--ui-test-seed-screen-backlog",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let pillProbe = app.descendants(matching: .any)["dayHome.statusPill.state.stalled"]
        XCTAssertTrue(pillProbe.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["dayHome.statusPill.state.syncing"].exists)

        let tryAgain = app.descendants(matching: .any)["shell.pane.status.stall.tryAgain"]
        self.scrollToElement(tryAgain, in: app)
        XCTAssertTrue(tryAgain.exists)
        XCTAssertFalse(tryAgain.isEnabled)

        let checkConnection = app.descendants(matching: .any)["shell.pane.status.checkConnection"]
        self.scrollToElement(checkConnection, in: app)
        XCTAssertTrue(checkConnection.exists)
    }

    @MainActor
    func testFreshLaunchConnectingState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-stall=fresh",
            "--ui-test-open-pane=status",
            "--ui-test-reset-on-this-phone",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let pillProbe = app.descendants(matching: .any)["dayHome.statusPill.state.connecting"]
        XCTAssertTrue(pillProbe.waitForExistence(timeout: 10))

        let leadProbe = app.descendants(matching: .any)["shell.pane.status.leadState.connecting"]
        XCTAssertTrue(leadProbe.waitForExistence(timeout: 10))

        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.stall.reason"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.stall.tryAgain"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.stall.pairAgain"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.checkConnection"].exists)
    }

    @MainActor
    func testPhoneSheetPairAgainNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-stall=stalled",
            "--ui-test-open-pane=status",
            "--ui-test-seed-screen-backlog",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")

        let pairAgain = app.descendants(matching: .any)["shell.pane.status.stall.pairAgain"]
        self.scrollToElement(pairAgain, in: app)
        XCTAssertTrue(pairAgain.waitForExistence(timeout: 5))
        pairAgain.tap()

        let title = app.staticTexts["pairFlow.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        app.buttons["back"].tap()
        XCTAssertFalse(title.exists)

        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.heading"].exists)
        self.scrollToElement(pairAgain, in: app)
        XCTAssertTrue(pairAgain.exists)
        XCTAssertFalse(app.buttons["get started"].exists)
    }

    @MainActor
    func testPersistenceAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-no-journal",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        app.terminate()

        app.launchArguments = [
            "--ui-test",
            "--ui-test-stall=stalled",
            "--ui-test-seed-screen-backlog",
        ]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["dayHome.statusPill.state.stalled"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testStalledLargeBacklogConcatenatesCountOnce() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-stall=stalled",
            "--ui-test-seed-large-backlog",
            "--ui-test-seed-large-backlog-count=42",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let pillButton = app.buttons["dayHome.statusPill"]
        XCTAssertTrue(pillButton.waitForExistence(timeout: 10))

        let labelString: String = {
            if let str = pillButton.label as String? { return str }
            return ""
        }()
        let valueString: String = {
            if let str = pillButton.value as? String { return str }
            if let num = pillButton.value as? NSNumber { return num.stringValue }
            return ""
        }()
        let combined = labelString + " " + valueString
        let count = combined.components(separatedBy: "42").count - 1
        XCTAssertEqual(count, 1, "Expected '42' to appear exactly once in combined label and value: '\(combined)'")
    }

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
