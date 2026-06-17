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
    func testOnThisPhoneEmptyShowsTurnOnSourceAndNoBackedUpBanner() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-reset-on-this-phone"])

        let turnOnSource = app.buttons["onThisPhone.turnOnSource"]
        XCTAssertTrue(turnOnSource.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["onThisPhone.notBackedUp"].exists)

        turnOnSource.tap()
        XCTAssertTrue(app.buttons["source.row.audio"].waitForExistence(timeout: 5))
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
        let greeting = app.staticTexts["dayHome.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 5))
        XCTAssertTrue(["good morning", "good afternoon", "good evening"].contains(greeting.label))
        let locality = app.buttons["dayHome.locality"]
        XCTAssertTrue(locality.waitForExistence(timeout: 5))
        XCTAssertEqual(locality.label, "your journal · on this phone")
        XCTAssertFalse(app.navigationBars["on this phone"].exists)
        XCTAssertFalse(app.staticTexts["placeholder.today"].exists)

        app.tabBars.buttons["ask"].tap()
        XCTAssertTrue(app.staticTexts["placeholder.ask"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testJournalLivesSheetShowsPositionsAndDismisses() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        app.buttons["dayHome.locality"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.sheet"].waitForExistence(timeout: 5))

        let promise = app.descendants(matching: .any)["journalLives.promise"]
        XCTAssertTrue(promise.exists)
        XCTAssertEqual(promise.label, "your journal is always private, only yours.")

        XCTAssertTrue(app.staticTexts["your observations rest here, yours and nowhere else."].exists)
        XCTAssertTrue(app.staticTexts["pair to a solstone on your computer — everything gathered so far flows in."].exists)
        XCTAssertTrue(app.staticTexts["a journal sol pbc keeps for you. operated by sol pbc."].exists)

        XCTAssertTrue(app.descendants(matching: .any)["journalLives.onThisPhone.current"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["journalLives.ownJournal.current"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["journalLives.hosted.current"].exists)

        XCTAssertFalse(app.buttons["journalLives.hosted"].exists)
        let comingLater = app.descendants(matching: .any)["journalLives.hosted.comingLater"]
        XCTAssertTrue(comingLater.exists)
        XCTAssertEqual(comingLater.label, "coming later")

        app.buttons["done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.sheet"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].exists)
    }

    @MainActor
    func testJournalLivesConnectReachesPairFlow() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        app.buttons["dayHome.locality"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.sheet"].waitForExistence(timeout: 5))
        app.buttons["journalLives.ownJournal"].tap()

        XCTAssertTrue(app.staticTexts["pair your solstone"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAskWarmEmptyShowsCountTieBack() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        app.tabBars.buttons["ask"].tap()
        let body = app.staticTexts["placeholder.ask"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sol answers from your journal"].waitForExistence(timeout: 5))
        XCTAssertEqual(body.label, "your phone has gathered 6 observations, resting here. connect a journal and sol can read all of them and answer.")
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
    func testSeededOnThisPhoneDropGuardrailShowsSnackbar() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])
        let rowID = "onThisPhone.row.audio:00000000-0000-0000-0000-000000000001:seed-audio-1"
        let row = app.descendants(matching: .any)[rowID]
        XCTAssertTrue(row.waitForExistence(timeout: 10), rowID)
        row.tap()

        let dropButton = app.buttons["onThisPhone.drop.button"]
        XCTAssertTrue(dropButton.waitForExistence(timeout: 5), rowID)
        dropButton.tap()
        XCTAssertTrue(app.staticTexts["drop this from this phone?"].waitForExistence(timeout: 5), rowID)

        let confirmButtons = app.buttons.matching(identifier: "onThisPhone.drop.confirm")
        let confirmButton = confirmButtons.firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), rowID)
        let actionableConfirmButton = confirmButtons.count > 1
            ? confirmButtons.element(boundBy: 1)
            : confirmButton
        actionableConfirmButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.drop.snackbar"].waitForExistence(timeout: 5), rowID)
        XCTAssertTrue(app.staticTexts["dropped “1m 15s of audio”."].waitForExistence(timeout: 5), rowID)
        XCTAssertFalse(app.descendants(matching: .any)[rowID].waitForExistence(timeout: 2), rowID)
    }

    @MainActor
    func testSeededOnThisPhoneSwipeToDropThenUndo() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])
        let rowID = "onThisPhone.row.audio:00000000-0000-0000-0000-000000000001:seed-audio-1"
        let row = app.descendants(matching: .any)[rowID]
        XCTAssertTrue(row.waitForExistence(timeout: 10), rowID)

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        )
        let confirmTitle = app.staticTexts["drop this from this phone?"]
        XCTAssertTrue(confirmTitle.waitForExistence(timeout: 5), rowID)

        let confirmButtons = app.descendants(matching: .any).matching(identifier: "onThisPhone.swipe.drop.confirm")
        let confirmButton = confirmButtons.firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), rowID)
        let actionableConfirmButton = confirmButtons.count > 1
            ? confirmButtons.element(boundBy: 1)
            : confirmButton
        actionableConfirmButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.drop.snackbar"].waitForExistence(timeout: 5), rowID)
        XCTAssertTrue(app.staticTexts["dropped “1m 15s of audio”."].waitForExistence(timeout: 5), rowID)
        XCTAssertTrue(app.descendants(matching: .any)[rowID].waitForNonExistence(timeout: 0.5), rowID)

        let undoButton = app.descendants(matching: .any)["onThisPhone.drop.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5), rowID)
        undoButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)[rowID].waitForExistence(timeout: 3), rowID)
        XCTAssertFalse(app.descendants(matching: .any)["onThisPhone.drop.snackbar"].waitForExistence(timeout: 2), rowID)
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
