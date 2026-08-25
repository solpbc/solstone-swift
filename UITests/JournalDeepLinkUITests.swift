// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class JournalDeepLinkUITests: XCTestCase {
    @MainActor
    func testJournalDeepLinkOpensPhoneSheet() throws {
        let app = self.launchApp()
        try XCTSkipIf(self.isPadShapedWindow(app), "the journal sheet is the phone shell's presentation")

        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.journal"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testJournalDeepLinkOpensPadPane() throws {
        let app = self.launchApp()
        try XCTSkipUnless(self.isPadShapedWindow(app), "the journal pane is the iPad shell's presentation")

        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.journal"].waitForExistence(timeout: 10))
    }
}

private extension JournalDeepLinkUITests {
    @MainActor
    func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=journal"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

}
