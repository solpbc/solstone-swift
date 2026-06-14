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
    func testAudioEnrollmentAvailableAtZeroJournal() {
        let app = self.launchNoJournalApp()

        app.tabBars.buttons["sense"].tap()
        let audioRow = app.buttons["source.row.audio"]
        XCTAssertTrue(audioRow.waitForExistence(timeout: 5))
        audioRow.tap()

        let valueBlock = app.staticTexts["audioEnrollment.value"]
        XCTAssertTrue(valueBlock.waitForExistence(timeout: 5))
        XCTAssertEqual(valueBlock.label, "what you say and the sound around you — kept on this phone, yours alone, until you connect a journal. turn it on only when you want solstone alongside you.")
        let turnOnAudio = app.buttons["turn on audio"]
        XCTAssertTrue(turnOnAudio.waitForExistence(timeout: 5))
        XCTAssertTrue(turnOnAudio.isEnabled)
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
    func testAskWarmEmptyShowsCountTieBack() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        app.tabBars.buttons["ask"].tap()
        XCTAssertTrue(app.staticTexts["placeholder.ask"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["nothing to ask yet"].waitForExistence(timeout: 5))

        let count = app.staticTexts["placeholder.ask.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "6 observations are waiting on this phone.")
    }

    @MainActor
    func testAudioMagicMomentShownPersistsAcrossRelaunch() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-seed-audio-magic",
            "--ui-test-seed-audio-magic-duration=185",
        ])

        XCTAssertTrue(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 10))
        let duration = app.staticTexts["magicMoment.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.label, "3m 5s")

        app.terminate()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.openTodayTabIfNeeded(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testAudioMagicMomentDurationTracksSeededDuration() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-seed-audio-magic",
            "--ui-test-seed-audio-magic-duration=242",
        ])

        XCTAssertTrue(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 10))
        let duration = app.staticTexts["magicMoment.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.label, "4m 2s")
    }

    @MainActor
    func testAudioEnrollmentPermissionDeniedDoesNotShowMagicMoment() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-reset-audio-l5",
            "--ui-test-observer-permission-denied",
        ])

        app.tabBars.buttons["sense"].tap()
        let audioRow = app.buttons["source.row.audio"]
        XCTAssertTrue(audioRow.waitForExistence(timeout: 5))
        audioRow.tap()

        let turnOnAudio = app.buttons["turn on audio"]
        XCTAssertTrue(turnOnAudio.waitForExistence(timeout: 5))
        turnOnAudio.tap()
        XCTAssertTrue(app.staticTexts["microphone access is required to listen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["turn on audio"].exists)

        app.tabBars.buttons["today"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSeededOnThisPhoneSummaryUsesSendStatePills() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        XCTAssertTrue(app.staticTexts["5 on this phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 needs attention"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["onThisPhone.summary.savedOnThisPhone"].exists)
        XCTAssertTrue(app.staticTexts["onThisPhone.summary.needsAttention"].exists)
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

            let dropButton = app.buttons["drop from this phone"]
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
