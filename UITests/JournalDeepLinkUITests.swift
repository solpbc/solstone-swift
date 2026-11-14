// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class JournalDeepLinkUITests: XCTestCase {
    @MainActor
    func testMalformedJournalLinkShowsNoticeWarmAndCold() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        for cold in [false, true] {
            if cold { app.terminate() }
            let link = URL(string: "solstone://open#bad=target")!
            if cold { app.open(link) } else { XCUIDevice.shared.system.open(link) }
            let notice = app.alerts.firstMatch
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = cold ? "journal-link-invalid-cold" : "journal-link-invalid-warm"
            shot.lifetime = .keepAlways
            self.add(shot)
            notice.buttons.firstMatch.tap()
            XCTAssertFalse(notice.exists)
        }
    }

    @MainActor
    func testJournalLinkOpensUnpairedSetupWarmAndCold() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        for cold in [false, true] {
            if cold { app.terminate() }
            let link = URL(string: "solstone://open#AbC-_~173012")!
            if cold { app.open(link) } else { XCUIDevice.shared.system.open(link) }
            XCTAssertTrue(app.buttons["journal.alreadyHaveOne"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
    }

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
