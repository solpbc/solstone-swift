// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// Drives each shell pane and attaches a screenshot, so a reviewing session can look at the
/// owner's pixels. Validation for the mobile-shell arc is the simulator plus screenshots
/// (founder ruling 2026-08-22); `test/capture_shots.sh` covers launch states and cannot tap,
/// so panes are captured here.
///
/// Extract after a run:
///   xcrun xcresulttool export attachments --path build/ci-ios-test-attempt-1.xcresult \
///     --output-path /tmp/shots
final class ShellPaneShotTests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-no-journal"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 15),
            "deck never appeared"
        )
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Every pane, captured at rest. Each assertion is what makes the shot worth looking at:
    /// a screenshot of a pane that never opened looks like a screenshot of the deck.
    func testCaptureEachPaneAtRest() {
        let app = launch()
        attach(app, "00-deck")

        // shelf — the one pane that is a ZStack sibling rather than a sheet
        let shelfOpener = app.buttons["dayHome.yourSolstoneEntry"]
        XCTAssertTrue(shelfOpener.waitForExistence(timeout: 10), "shelf opener missing")
        shelfOpener.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10),
            "shelf heading missing"
        )
        attach(app, "01-shelf")
        app.swipeLeft()

        // status — the zoom-anchored sheet
        let statusOpener = app.buttons["dayHome.statusPill"]
        if statusOpener.waitForExistence(timeout: 10) {
            statusOpener.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 10),
                "status heading missing"
            )
            attach(app, "02-status")
            app.swipeDown(velocity: .fast)
        }

        // journal setup — unpaired, so the pill is the setup door rather than the journal
        let journalDoor = app.buttons["dayHome.journalSetup"]
        if journalDoor.waitForExistence(timeout: 5) {
            journalDoor.tap()
            attach(app, "03-journal-setup")
        }
    }

    /// The AX5 + landscape pass. These are threshold behaviours the default size cannot show:
    /// the deck's reflow, the pill leaving the bar, and ruling 7's full-window panes.
    func testCaptureAccessibilityThresholds() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-no-journal"]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] =
            "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 15),
            "deck never appeared at AX5"
        )
        attach(app, "10-deck-ax5-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        attach(app, "11-deck-ax5-landscape")

        let shelfOpener = app.buttons["dayHome.yourSolstoneEntry"]
        if shelfOpener.waitForExistence(timeout: 10) {
            shelfOpener.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10),
                "shelf heading missing in landscape at AX5"
            )
            attach(app, "12-shelf-ax5-landscape")
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
