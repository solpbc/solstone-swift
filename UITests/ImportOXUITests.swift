// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

final class ImportOXUITests: XCTestCase {
    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        self.add(shot)
    }

    @MainActor
    private func platformTag(_ app: XCUIApplication) -> String {
        UITestsIsPadShapedWindow(app) ? "ipad" : "iphone"
    }

    @MainActor
    private func revealImportTile(in app: XCUIApplication) {
        let entry = app.buttons["dayHome.importEntry"]
        let surface = app.scrollViews["dayHome.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if entry.exists {
                let footer = app.buttons["dayHome.journalSetup"].exists
                    ? app.buttons["dayHome.journalSetup"] : app.buttons["dayHome.openInJournal"]
                let bottom = footer.exists ? footer.frame.minY : app.frame.maxY - 34
                let nav = app.navigationBars.firstMatch
                let top = nav.exists ? nav.frame.maxY : app.frame.minY
                if entry.isHittable, entry.frame.minY >= top, entry.frame.maxY <= bottom {
                    return
                }
            }
            surface.swipeUp()
        }
    }

    @MainActor
    private func scrollUntilVisible(
        _ element: XCUIElement,
        in container: XCUIElement,
        swipeUp: Bool = true,
        attempts: Int = 8
    ) {
        for _ in 0..<attempts {
            if element.exists && element.isHittable {
                return
            }
            if swipeUp {
                container.swipeUp()
            } else {
                container.swipeDown()
            }
        }
    }

    /// Verifies `more imports` is hidden when unpaired and when awaiting mark confirmation,
    /// while `files` remains live for offline queueing.
    @MainActor
    func testMoreImportsHiddenWhenUnpairedOrAwaitingMarkConfirmation() {
        let unpaired = XCUIApplication()
        unpaired.launchArguments += [
            "--ui-test",
            "--ui-test-no-journal",
            "--ui-test-reset-on-this-phone",
            "--ui-test-open-pane=import",
        ]
        unpaired.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        unpaired.launch()
        XCTAssertTrue(unpaired.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(unpaired.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10))
        XCTAssertTrue(unpaired.buttons["import.pickFiles"].waitForExistence(timeout: 5))
        XCTAssertFalse(unpaired.buttons["import.moreImports"].exists)
        XCTAssertTrue(unpaired.staticTexts["import.recent.empty"].waitForExistence(timeout: 5))
        unpaired.terminate()

        let awaitingMark = XCUIApplication()
        awaitingMark.launchArguments += [
            "--ui-test",
            "--ui-test-awaiting-mark-confirmation",
            "--ui-test-reset-on-this-phone",
            "--ui-test-open-pane=import",
        ]
        awaitingMark.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        awaitingMark.launch()
        XCTAssertTrue(awaitingMark.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(awaitingMark.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10))
        XCTAssertTrue(awaitingMark.buttons["import.pickFiles"].waitForExistence(timeout: 5))
        XCTAssertFalse(awaitingMark.buttons["import.moreImports"].exists)
    }

    /// Verifies the inline Import OX pane (waiting for your review, expired copy, on this device
    /// retryable + non-retryable attention + waiting, 24h recent receipts, unified remove confirm
    /// dialog) and captures screenshots of Home `import` tile and Import pane in the simulator's
    /// active appearance (run under both `simctl ui appearance light` and `dark`).
    @MainActor
    func testInlineImportOXFlowAndShots() {
        // 1. Review-only seed: Home tile shows orange `ready to review` with `export.zip`
        let reviewApp = XCUIApplication()
        reviewApp.launchArguments += [
            "--ui-test",
            "--ui-test-journal-mark",
            "--ui-test-seed-import-ox-review-only",
        ]
        reviewApp.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        reviewApp.launch()
        XCTAssertTrue(reviewApp.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(reviewApp.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 15))
        let device = self.platformTag(reviewApp)
        self.revealImportTile(in: reviewApp)
        let tile = reviewApp.buttons["dayHome.importEntry"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        self.attach(reviewApp, "import-ox-home-review-\(device)")
        reviewApp.terminate()

        // 2. Full Import OX seed: Home tile (`needs attention`) + inline Import pane (all sections)
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test",
            "--ui-test-journal-mark",
            "--ui-test-seed-import-ox",
        ]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 15))
        self.revealImportTile(in: app)
        self.attach(app, "import-ox-home-attention-\(device)")

        self.tapDayHomeImportEntry(in: app)
        let importPane = app.descendants(matching: .any)["shell.pane.import"]
        XCTAssertTrue(importPane.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["import.moreImports"].waitForExistence(timeout: 5))
        let reviewHeading = app.staticTexts["import.section.waitingForReview"]
        XCTAssertTrue(reviewHeading.waitForExistence(timeout: 10))
        let openReviewBtn = app.buttons["import.review.open.00000000-0000-0000-0000-000000090001"]
        let sendAgainBtn = app.buttons["import.review.sendAgain.00000000-0000-0000-0000-000000090002"]
        self.scrollUntilVisible(openReviewBtn, in: importPane, swipeUp: true)
        XCTAssertTrue(openReviewBtn.waitForExistence(timeout: 5))
        XCTAssertTrue(sendAgainBtn.waitForExistence(timeout: 5))
        self.attach(app, "import-ox-pane-review-\(device)")

        // Scroll to reveal `on this device` + `recent`
        let retryBtn = app.buttons["import.onDevice.tryNow.00000000-0000-0000-0000-000000090004"]
        self.scrollUntilVisible(retryBtn, in: importPane, swipeUp: true)
        XCTAssertTrue(app.staticTexts["import.section.onThisDevice"].waitForExistence(timeout: 10))
        // Non-retryable `plan_failed` row must NOT show `try now`
        XCTAssertFalse(app.buttons["import.onDevice.tryNow.00000000-0000-0000-0000-000000090003"].exists)
        // Retryable `already_running` row MUST show `try now`
        XCTAssertTrue(retryBtn.waitForExistence(timeout: 5))
        self.attach(app, "import-ox-pane-ondevice-\(device)")

        let allHistoryBtn = app.buttons["import.recent.allHistory"]
        self.scrollUntilVisible(allHistoryBtn, in: importPane, swipeUp: true)
        XCTAssertTrue(app.staticTexts["import.section.recent"].waitForExistence(timeout: 10))
        XCTAssertTrue(allHistoryBtn.waitForExistence(timeout: 5))
        self.attach(app, "import-ox-pane-recent-\(device)")

        // Verify unified remove confirmation dialog works on review item
        let removeBtn = app.buttons["import.review.remove.00000000-0000-0000-0000-000000090001"]
        self.scrollUntilVisible(removeBtn, in: importPane, swipeUp: false)
        XCTAssertTrue(removeBtn.waitForExistence(timeout: 5))
        removeBtn.tap()
        let confirmBtn = app.buttons["import.remove.confirm"].firstMatch
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 5))
        confirmBtn.tap()
        XCTAssertTrue(removeBtn.waitForNonExistence(timeout: 5))

        app.terminate()
    }
}
