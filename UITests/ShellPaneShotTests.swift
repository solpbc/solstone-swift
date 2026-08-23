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

    @MainActor
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

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Every pane, captured at rest. Each assertion is what makes the shot worth looking at:
    /// a screenshot of a pane that never opened looks like a screenshot of the deck.
    @MainActor
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
        app.buttons["done"].tap()

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
    @MainActor
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

    /// Owned L2.3 leaves at default type, light, portrait.
    @MainActor
    func testCaptureOwnedLeavesDefaultLight() {
        self.captureOwnedLeaves(suffix: "light", style: "Light", ax5: false, landscape: false)
    }

    /// Owned L2.3 leaves at default type, dark, portrait.
    @MainActor
    func testCaptureOwnedLeavesDefaultDark() {
        self.captureOwnedLeaves(suffix: "dark", style: "Dark", ax5: false, landscape: false)
    }

    /// Owned L2.3 leaves at AX5, light, portrait.
    @MainActor
    func testCaptureOwnedLeavesAX5() {
        self.captureOwnedLeaves(suffix: "ax5", style: "Light", ax5: true, landscape: false)
    }

    /// Owned L2.3 leaves at default type, light, iPhone landscape.
    @MainActor
    func testCaptureOwnedLeavesLandscape() {
        self.captureOwnedLeaves(suffix: "landscape", style: "Light", ax5: false, landscape: true)
    }

    /// Splash is a launch state, not a tap target. Captured here so landscape and AX5
    /// exist in the UITest attachments; `make sim-shots` covers splash/deck appearance.
    @MainActor
    func testCaptureSplashAxes() {
        self.captureSplash(name: "30-splash-light", style: "Light", ax5: false, landscape: false)
        self.captureSplash(name: "31-splash-dark", style: "Dark", ax5: false, landscape: false)
        self.captureSplash(name: "32-splash-ax5", style: "Light", ax5: true, landscape: false)
        self.captureSplash(name: "33-splash-landscape", style: "Light", ax5: false, landscape: true)
    }
}

@MainActor
private extension ShellPaneShotTests {
    func launchOwned(style: String, ax5: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test",
            "--ui-test-no-journal",
            "--ui-test-seed-on-this-phone",
            "-AppleInterfaceStyle",
            style,
        ]
        if ax5 {
            app.launchEnvironment["UIPreferredContentSizeCategoryName"] =
                "UICTContentSizeCategoryAccessibilityXXXL"
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 15),
            "deck never appeared"
        )
        return app
    }

    func captureOwnedLeaves(suffix: String, style: String, ax5: Bool, landscape: Bool) {
        let app = self.launchOwned(style: style, ax5: ax5)
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 2)
        }
        defer {
            if landscape {
                XCUIDevice.shared.orientation = .portrait
            }
        }

        self.captureSourceDetail(
            in: app,
            tileID: "dayHome.tile.audio",
            markerID: "source.homeTile.audio",
            name: "20-audio-\(suffix)"
        )
        self.captureSourceDetail(
            in: app,
            tileID: "dayHome.tile.location",
            markerID: "source.homeTile.location",
            name: "21-location-\(suffix)"
        )
        self.captureSourceDetail(
            in: app,
            tileID: "dayHome.tile.screencast",
            markerID: "source.homeTile.screencast",
            name: "22-screencast-\(suffix)"
        )
        self.captureSourceDetail(
            in: app,
            tileID: "dayHome.tile.omi",
            markerID: "source.homeTile.omi",
            name: "23-omi-\(suffix)"
        )

        let watchTile = app.buttons["dayHome.tile.watch"]
        var capturedWatch = false
        if watchTile.waitForExistence(timeout: 3) {
            self.captureSourceDetail(
                in: app,
                tileID: "dayHome.tile.watch",
                markerID: "source.homeTile.watch",
                name: "24-watch-\(suffix)"
            )
            capturedWatch = true
        }

        self.tapHittable(app.buttons["dayHome.importEntry"], in: app, missing: "import tile missing")
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10),
            "import pane missing"
        )
        self.attach(app, "25-import-\(suffix)")

        let onThisDevice = app.buttons["on this device"]
        XCTAssertTrue(onThisDevice.waitForExistence(timeout: 10), "on this device door missing")
        onThisDevice.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10),
            "on this device surface missing"
        )
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "onThisPhone.row.transfer:mobile-segment:",
            ":audio"
        )).firstMatch
        self.scrollTo(row, in: app.descendants(matching: .any)["onThisPhone.surface"])
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded on-this-device row missing")
        row.tap()
        XCTAssertTrue(
            app.buttons["onThisPhone.drop.button"].waitForExistence(timeout: 10),
            "on-this-device item detail missing"
        )
        self.attach(app, "26-onThisPhoneItem-\(suffix)")

        self.popNavigation(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10),
            "on this device missing after item-detail pop"
        )
        self.popNavigation(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10),
            "import missing after on-this-device pop"
        )
        self.popNavigation(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.import"].waitForNonExistence(timeout: 10),
            "import still present after pop to deck"
        )

        self.tapHittable(app.buttons["dayHome.sourcesEntry"], in: app, missing: "add more tile missing")
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.addMore"].waitForExistence(timeout: 10),
            "add more pane missing"
        )
        self.attach(app, "27-addMore-\(suffix)")

        if !capturedWatch {
            let watchRow = app.buttons["source.row.watch"]
            XCTAssertTrue(watchRow.waitForExistence(timeout: 10), "watch row missing in add more")
            watchRow.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["source.homeTile.watch"].waitForExistence(timeout: 10),
                "watch detail missing"
            )
            self.attach(app, "24-watch-\(suffix)")
            self.popNavigation(in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)["shell.pane.addMore"].waitForExistence(timeout: 10),
                "add more missing after watch pop"
            )
        }

        self.dismissSheet(in: app, untilMissing: "shell.pane.addMore")
    }

    func captureSplash(name: String, style: String, ax5: Bool, landscape: Bool) {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test",
            "--ui-test-onboarding-step=welcome",
            "-AppleInterfaceStyle",
            style,
        ]
        if ax5 {
            app.launchEnvironment["UIPreferredContentSizeCategoryName"] =
                "UICTContentSizeCategoryAccessibilityXXXL"
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.buttons["get started"].waitForExistence(timeout: 15),
            "splash CTA missing"
        )
        XCTAssertTrue(
            app.staticTexts["welcome to solstone."].waitForExistence(timeout: 5),
            "splash title missing"
        )
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 2)
        }
        self.attach(app, name)
        if landscape {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func captureSourceDetail(
        in app: XCUIApplication,
        tileID: String,
        markerID: String,
        name: String
    ) {
        self.tapHittable(app.buttons[tileID], in: app, missing: "\(tileID) missing")
        XCTAssertTrue(
            app.descendants(matching: .any)[markerID].waitForExistence(timeout: 10),
            "\(markerID) missing after opening \(tileID)"
        )
        self.attach(app, name)
        self.popNavigation(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)[markerID].waitForNonExistence(timeout: 10),
            "\(markerID) still present after pop"
        )
    }

    func tapHittable(_ element: XCUIElement, in app: XCUIApplication, missing message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), message)
        if !element.isHittable {
            app.swipeUp()
        }
        if !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(message) (not hittable)")
        element.tap()
    }

    func popNavigation(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "back button missing")
        back.tap()
    }

    func dismissSheet(in app: XCUIApplication, untilMissing identifier: String) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        top.press(forDuration: 0.1, thenDragTo: bottom)
        XCTAssertTrue(
            app.descendants(matching: .any)[identifier].waitForNonExistence(timeout: 5),
            "\(identifier) still present after sheet dismiss"
        )
    }

    func scrollTo(_ element: XCUIElement, in surface: XCUIElement) {
        if element.waitForExistence(timeout: 1) {
            return
        }
        XCTAssertTrue(surface.waitForExistence(timeout: 5), "scroll surface missing")
        for _ in 0..<5 {
            surface.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return
            }
        }
    }
}
