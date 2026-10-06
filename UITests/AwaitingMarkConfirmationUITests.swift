// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class AwaitingMarkConfirmationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testStatusPaneAsksAgain() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-awaiting-mark-confirmation",
            "--ui-test-open-pane=status",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let leadProbe = app.descendants(matching: .any)["shell.pane.status.leadState.awaitingMarkConfirmation"]
        XCTAssertTrue(leadProbe.waitForExistence(timeout: 10))

        let awaitingRegion = app.descendants(matching: .any)["shell.pane.status.awaitingMarkConfirmation"]
        self.scrollToElement(awaitingRegion, in: app)
        XCTAssertTrue(awaitingRegion.waitForExistence(timeout: 10))

        let connectedRegion = app.descendants(matching: .any)["shell.pane.status.connected"]
        XCTAssertFalse(connectedRegion.exists)

        awaitingRegion.tap()

        let pairFlowTitle = app.descendants(matching: .any)["pairFlow.title"]
        XCTAssertTrue(pairFlowTitle.waitForExistence(timeout: 10))

        let backButton = app.buttons["back"]
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }

        if !awaitingRegion.exists {
            let statusPill = app.buttons["dayHome.statusPill"]
            if statusPill.waitForExistence(timeout: 5) {
                statusPill.tap()
            }
        }

        self.scrollToElement(awaitingRegion, in: app)
        XCTAssertTrue(awaitingRegion.waitForExistence(timeout: 10))
        awaitingRegion.tap()

        XCTAssertTrue(pairFlowTitle.waitForExistence(timeout: 10))
    }

    @MainActor
    func testConnectedPaneWithoutAwaitingArgument() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-open-pane=status",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let heading = app.descendants(matching: .any)["shell.pane.status.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))

        let connectedRegion = app.descendants(matching: .any)["shell.pane.status.connected"]
        self.scrollToElement(connectedRegion, in: app)
        XCTAssertTrue(connectedRegion.waitForExistence(timeout: 10))

        let awaitingLead = app.descendants(matching: .any)["shell.pane.status.leadState.awaitingMarkConfirmation"]
        XCTAssertFalse(awaitingLead.exists)

        let awaitingRegion = app.descendants(matching: .any)["shell.pane.status.awaitingMarkConfirmation"]
        XCTAssertFalse(awaitingRegion.exists)
    }
}

@MainActor
private extension AwaitingMarkConfirmationUITests {
    func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 2) {
            return
        }
        let scrollContainer = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.scrollViews.firstMatch
        if scrollContainer.waitForExistence(timeout: 5) {
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
}
