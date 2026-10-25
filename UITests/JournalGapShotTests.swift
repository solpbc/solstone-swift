// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// Home with the gap, the status that names it, that status caught up, and the clean home.
final class JournalGapShotTests: XCTestCase {
    private let gapHeadline = "there's a gap in your journal"
    private let dayLine = "some of what you shared today didn't reach it."

    @MainActor
    func testCaptureTheGapAndTheCaughtUpHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-seed-journal-loss"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone sheet is the phone lane's")
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 20))
        XCTAssertTrue(self.headline(self.gapHeadline, in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.statusPill.state.journalGap"].waitForExistence(timeout: 5))
        self.attach(app, "01-home-gap")

        app.buttons["dayHome.statusPill"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(self.headline(self.gapHeadline, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(self.headline(self.dayLine, in: app).waitForExistence(timeout: 10))
        self.attach(app, "02-status-gap")

        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.statusPill.state.caughtUp"].waitForExistence(timeout: 10))
        app.buttons["dayHome.statusPill"].tap()
        XCTAssertTrue(self.headline("all caught up", in: app).waitForExistence(timeout: 10))
        self.attach(app, "03-status-caught-up")

        app.terminate()
        let clean = XCUIApplication()
        clean.launchArguments = ["--ui-test"]
        clean.launch()
        XCTAssertTrue(clean.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(clean.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 20))
        XCTAssertTrue(clean.descendants(matching: .any)["dayHome.statusPill.state.caughtUp"].waitForExistence(timeout: 20))
        XCTAssertTrue(self.headline("connected", in: clean).waitForExistence(timeout: 10))
        self.attach(clean, "04-home-caught-up")
    }

    @MainActor
    private func headline(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        self.add(shot)
    }
}
