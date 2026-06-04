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

        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["placeholder.today"].exists)
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

        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10))
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
    func testNoJournalSourcesShowsUnpairedTrustLineAndConnectBanner() {
        let app = self.launchNoJournalApp()

        app.tabBars.buttons["sense"].tap()

        let footer = app.staticTexts["sources.trustLine"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertEqual(
            footer.label,
            "kept on this phone, only — nowhere else, until you connect a journal"
        )

        let banner = app.buttons["sources.connectBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        banner.tap()

        XCTAssertTrue(app.buttons["connectJournal.ownJournal"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testConnectEntryOpensPairFlowAndHostedDoorIsHidden() {
        let app = self.launchNoJournalApp()

        app.buttons["onThisPhone.connectJournal"].tap()
        XCTAssertTrue(app.navigationBars["connect a journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["your own journal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connectJournal.hostedJournal"].exists)

        app.buttons["connectJournal.ownJournal"].tap()
        XCTAssertTrue(app.staticTexts["pair your solstone"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSeededNoJournalTodayShowsOnThisPhoneSurfaceAndAskPlaceholder() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["on this phone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["placeholder.today"].exists)

        app.tabBars.buttons["ask"].tap()
        XCTAssertTrue(app.staticTexts["placeholder.ask"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSeededOnThisPhoneCountsUsePerSourceNouns() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        XCTAssertTrue(app.staticTexts["2 conversations"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3 places"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 thing"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSeededOnThisPhoneDeletesItemsByKind() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        let rows = [
            "onThisPhone.row.audio:00000000-0000-0000-0000-000000000001:seed-audio-1",
            "onThisPhone.row.location:20260603-110000_300",
            "onThisPhone.row.11111111-1111-1111-1111-111111111111",
        ]

        for rowID in rows {
            let row = app.descendants(matching: .any)[rowID]
            XCTAssertTrue(row.waitForExistence(timeout: 10), rowID)
            row.tap()

            let dropButton = app.buttons["drop"]
            XCTAssertTrue(dropButton.waitForExistence(timeout: 5), rowID)
            dropButton.tap()
            XCTAssertTrue(app.staticTexts["deleted from this phone"].waitForExistence(timeout: 5), rowID)

            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertFalse(app.descendants(matching: .any)[rowID].waitForExistence(timeout: 2), rowID)
        }
    }

    @MainActor
    func testOnThisPhoneNotBackedUpNudgeOpensConnectSheet() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        XCTAssertTrue(app.staticTexts["onThisPhone.notBackedUp"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "onThisPhone.notBackedUp").count, 1)
        app.buttons["onThisPhone.connectJournal"].tap()
        XCTAssertTrue(app.navigationBars["connect a journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectJournal.ownJournal"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgedBacklogNudgeDismissalPersistsAcrossSeededLaunches() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-seed-aged-backlog",
            "--ui-test-reset-nudge-dismissal",
        ])
        let text = "51 observations are resting on this phone. connect a journal whenever you'd like a backup."

        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10))
        app.buttons["onThisPhone.agedBacklog.dismiss"].tap()
        XCTAssertFalse(app.staticTexts["onThisPhone.agedBacklog"].waitForExistence(timeout: 2))

        app.terminate()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal", "--ui-test-seed-aged-backlog"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.openTodayTabIfNeeded(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["onThisPhone.agedBacklog"].waitForExistence(timeout: 2))
    }
}

@MainActor
private extension NoJournalShellTests {
    func launchNoJournalApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal"]
        app.launchArguments.append(contentsOf: extraArguments)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.openTodayTabIfNeeded(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10))
        return app
    }

    func openTodayTabIfNeeded(in app: XCUIApplication) {
        let todayTab = app.tabBars.buttons["today"]
        if todayTab.waitForExistence(timeout: 2) {
            todayTab.tap()
        }
    }
}
