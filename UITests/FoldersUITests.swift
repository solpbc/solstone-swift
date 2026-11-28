// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// Structural and behavioral UI tests for the Folders source on iPhone and iPad.
/// Asserts navigation, state structure, and controls via accessibility identifiers only.
final class FoldersUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    private func tapDeckTile(_ identifier: String, in app: XCUIApplication) {
        let tile = app.buttons[identifier]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(identifier) missing")
        for _ in 0..<4 where !tile.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(tile.isHittable, "\(identifier) not hittable")
        tile.tap()
    }

    func testFoldersTileOpensListAndPushesFolderDetailAndControls() {
        let app = self.launch(["--ui-test-folders-state", "populated"])

        self.tapDeckTile("dayHome.tile.folders", in: app)

        let listPage = app.descendants(matching: .any)["folders.page"]
        XCTAssertTrue(listPage.waitForExistence(timeout: 8), "folders list page did not appear")
        XCTAssertTrue(app.buttons["folders.addFolder"].waitForExistence(timeout: 5))

        let activeRow = app.buttons["folders.row.reading-pdfs-11111111"]
        XCTAssertTrue(activeRow.waitForExistence(timeout: 5))
        activeRow.tap()

        let detail = app.descendants(matching: .any)["folders.detail.reading-pdfs-11111111"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8), "folder detail page did not push")
        XCTAssertTrue(app.buttons["folders.detail.pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["folders.detail.checkNow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["folders.detail.honesty"].exists)

        // Pausing switches from pause/honesty to resume, omitting the honesty line.
        app.buttons["folders.detail.pause"].tap()
        XCTAssertTrue(app.buttons["folders.detail.resume"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["folders.detail.honesty"].exists)

        // Resuming restores pause & honesty line.
        app.buttons["folders.detail.resume"].tap()
        XCTAssertTrue(app.buttons["folders.detail.pause"].waitForExistence(timeout: 5))
    }

    func testFoldersAttentionStateShowsRechooseControl() {
        let app = self.launch(["--ui-test-folders-state", "attention"])

        self.tapDeckTile("dayHome.tile.folders", in: app)

        let row = app.buttons["folders.row.field-docs-33333333"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()

        XCTAssertTrue(app.buttons["folders.detail.rechoose"].waitForExistence(timeout: 8))
    }

    func testPadSplitShowsDeckBesideFoldersListAndDetail() throws {
        let app = self.launch(["--ui-test-folders-state", "populated"])
        try XCTSkipUnless(self.isPadShapedWindow(app), "iPad split assertion runs on iPad lane")

        self.tapDeckTile("dayHome.tile.folders", in: app)

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].exists, "deck column should remain visible on iPad")
        XCTAssertTrue(app.descendants(matching: .any)["folders.page"].waitForExistence(timeout: 8))

        let row = app.buttons["folders.row.reading-pdfs-11111111"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.descendants(matching: .any)["folders.detail.reading-pdfs-11111111"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].exists, "deck column should remain visible beside pushed folder detail")
    }
}
