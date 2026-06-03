// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class NoJournalShellTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testNoJournalShellShowsPlaceholdersAndTabs() {
        let app = self.launchNoJournalApp()

        XCTAssertTrue(app.staticTexts["placeholder.today"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["portal.warmCard"].exists)

        app.tabBars.buttons["ask"].tap()
        XCTAssertTrue(app.staticTexts["placeholder.ask"].waitForExistence(timeout: 5))

        app.tabBars.buttons["sense"].tap()
        XCTAssertTrue(app.buttons["source.row.audio"].waitForExistence(timeout: 5))

        app.tabBars.buttons["more"].tap()
        XCTAssertTrue(app.navigationBars["more"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFreshOnboardingLookAroundLandsInNoJournalShell() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-onboarding-step=welcome"]
        app.launch()

        XCTAssertTrue(app.buttons["get started"].waitForExistence(timeout: 10))
        app.buttons["get started"].tap()
        XCTAssertTrue(app.staticTexts["start with a source"].waitForExistence(timeout: 5))
        app.buttons["onboarding.lookAround"].tap()

        XCTAssertTrue(app.staticTexts["placeholder.today"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAudioListenControlEnabledAtZeroJournal() {
        let app = self.launchNoJournalApp()

        app.tabBars.buttons["sense"].tap()
        let audioRow = app.buttons["source.row.audio"]
        XCTAssertTrue(audioRow.waitForExistence(timeout: 5))
        audioRow.tap()

        let listen = app.descendants(matching: .any)["source.listen"]
        if listen.waitForExistence(timeout: 5) {
            XCTAssertTrue(listen.isEnabled)
        } else {
            let start = app.buttons["start"]
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            XCTAssertTrue(start.isEnabled)
        }
    }

    @MainActor
    func testConnectEntryOpensPairFlowAndHostedDoorIsHidden() {
        let app = self.launchNoJournalApp()

        app.buttons["connect a journal"].tap()
        XCTAssertTrue(app.navigationBars["connect a journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["your own journal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connectJournal.hostedJournal"].exists)

        app.buttons["connectJournal.ownJournal"].tap()
        XCTAssertTrue(app.staticTexts["pair your solstone"].waitForExistence(timeout: 5))
    }
}

@MainActor
private extension NoJournalShellTests {
    func launchNoJournalApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        if !app.staticTexts["placeholder.today"].waitForExistence(timeout: 10) {
            let todayTab = app.tabBars.buttons["today"]
            if todayTab.waitForExistence(timeout: 2) {
                todayTab.tap()
            }
        }
        XCTAssertTrue(app.staticTexts["placeholder.today"].waitForExistence(timeout: 10))
        return app
    }
}
