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

        XCTAssertFalse(app.staticTexts["portal.warmCard"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].exists)

        self.tapDayHomeSourcesEntry(in: app)
        XCTAssertTrue(app.buttons["source.row.audio"].waitForExistence(timeout: 5))
        self.dismissPresentedSheet(in: app, untilMissingElementID: "source.row.audio")

        app.buttons["dayHome.yourSolstoneEntry"].tap()
        XCTAssertTrue(app.navigationBars["your journal"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOnThisPhoneEmptyShowsTurnOnSourceAndNoBackedUpBanner() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-reset-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)

        let turnOnSource = app.buttons["onThisPhone.turnOnSource"]
        XCTAssertTrue(turnOnSource.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["onThisPhone.truthLine"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onThisPhone.connectJournalButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["onThisPhone.notBackedUp"].exists)

        turnOnSource.tap()
        XCTAssertTrue(app.buttons["source.row.audio"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFreshOnboardingGetStartedLandsInNoJournalShell() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal", "--ui-test-onboarding-step=welcome"]
        app.launch()

        XCTAssertTrue(app.buttons["get started"].waitForExistence(timeout: 10))
        app.buttons["get started"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAudioEnrollmentAvailableAtZeroJournal() {
        let app = self.launchNoJournalApp()

        self.tapDayHomeSourcesEntry(in: app)
        let audioRow = app.buttons["source.row.audio"]
        XCTAssertTrue(audioRow.waitForExistence(timeout: 5))
        audioRow.tap()

        let valueBlock = app.staticTexts["audioEnrollment.value"]
        XCTAssertTrue(valueBlock.waitForExistence(timeout: 5))
        XCTAssertEqual(valueBlock.label, "what you say and the sound around you, on this device until you connect a journal. turn it on only when you want to share audio.")
        let turnOnAudio = app.buttons["turn on audio"]
        XCTAssertTrue(turnOnAudio.waitForExistence(timeout: 5))
        XCTAssertTrue(turnOnAudio.isEnabled)
    }

    @MainActor
    func testNoJournalSourcesShowsSimplifiedSheet() {
        let app = self.launchNoJournalApp()

        self.tapDayHomeSourcesEntry(in: app)

        XCTAssertTrue(app.staticTexts["experiencing your day with you"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["import other memories"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["source.row.audio"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sources.connectBanner"].exists)
        XCTAssertFalse(app.staticTexts["sources.trustLine"].exists)
        XCTAssertFalse(app.staticTexts["nothing is on right now"].exists)
    }

    @MainActor
    func testConnectEntryOpensPairFlowAndShowsOnYourPhoneLane() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-reset-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)

        app.buttons["onThisPhone.connectJournalButton"].tap()
        XCTAssertTrue(app.navigationBars["connect a journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["your own journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["connectJournal.onYourPhone"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)["connectJournal.onYourPhone.comingLater"].label,
            "coming later"
        )
        XCTAssertTrue(app.descendants(matching: .any)["connectJournal.noJournalYet"].exists)
        XCTAssertTrue(app.buttons["connectJournal.howJournalsWork"].exists)

        app.buttons["connectJournal.ownJournal"].tap()
        self.assertSinglePairFlowMarker(in: app)
    }

    @MainActor
    func testStandaloneOnThisPhoneViewHasNoAskBar() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)
        XCTAssertFalse(app.buttons["dayHome.askBar"].exists)
    }

    @MainActor
    func testSeededNoJournalTodayShowsOnThisPhoneSurface() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        self.assertDayHomeGreeting(in: app)
        XCTAssertFalse(app.buttons["dayHome.askBar"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["askPreview.sheet"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.surface"].exists)
        let status = app.buttons["dayHome.statusPill"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("on this device · not paired"), status.label)
        XCTAssertFalse(app.navigationBars["on this device"].exists)
    }

    @MainActor
    func testJournalLivesSheetShowsPositionsAndDismisses() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        let journalSetup = app.buttons["dayHome.journalSetup"]
        XCTAssertTrue(journalSetup.waitForExistence(timeout: 5))
        journalSetup.tap()
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.sheet"].waitForExistence(timeout: 5))

        let promise = app.descendants(matching: .any)["journalLives.promise"]
        XCTAssertTrue(promise.exists)
        XCTAssertEqual(promise.label, "your journal is always private, only yours.")

        XCTAssertTrue(app.staticTexts["your own journal"].exists)
        XCTAssertTrue(app.staticTexts["pair to your journal on your computer. everything you've shared so far flows in."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.onYourPhone"].exists)
        XCTAssertTrue(app.staticTexts["your journal as its own app, right on this device."].exists)
        XCTAssertTrue(app.staticTexts["right now, just your memories are on this device, waiting to be processed."].exists)
        XCTAssertFalse(app.staticTexts["your memories rest here, yours and nowhere else."].exists)

        let currentRows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "journalLives.",
            ".current"
        ))
        XCTAssertEqual(currentRows.count, 0)
        XCTAssertFalse(app.descendants(matching: .any)["journalLives.ownJournal.current"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["journalLives.onYourPhone.current"].exists)

        XCTAssertFalse(app.buttons["journalLives.onYourPhone"].exists)
        let comingLater = app.descendants(matching: .any)["journalLives.onYourPhone.comingLater"]
        XCTAssertTrue(comingLater.exists)
        XCTAssertEqual(comingLater.label, "coming later")

        app.buttons["done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.sheet"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].exists)
    }

    @MainActor
    func testJournalLivesConnectReachesPairFlow() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])

        let journalSetup = app.buttons["dayHome.journalSetup"]
        XCTAssertTrue(journalSetup.waitForExistence(timeout: 5))
        journalSetup.tap()
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.sheet"].waitForExistence(timeout: 5))
        app.buttons["journalLives.ownJournal"].tap()

        self.assertSinglePairFlowMarker(in: app)
    }

    @MainActor
    func testHowJournalsWorkPresentsJournalLivesAboveConnectSheet() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-reset-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)

        app.buttons["onThisPhone.connectJournalButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connectJournal.sheet"].waitForExistence(timeout: 5))
        app.buttons["connectJournal.howJournalsWork"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["journalLives.sheet"].waitForExistence(timeout: 5))

        app.buttons["journalLives.ownJournal"].tap()
        self.assertSinglePairFlowMarker(in: app)

        self.dismissPresentedSheet(in: app, untilMissingElementID: "journalLives.sheet")
        XCTAssertTrue(app.descendants(matching: .any)["connectJournal.sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["connect a journal"].exists)
    }

    @MainActor
    func testAudioMagicMomentShownPersistsAcrossRelaunch() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-seed-audio-magic",
            "--ui-test-seed-audio-magic-duration=185",
        ])
        self.openStandaloneOnThisPhoneBrowse(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 10))
        let duration = app.staticTexts["magicMoment.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.label, "3m 5s")

        app.terminate()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)
        self.openStandaloneOnThisPhoneBrowse(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testAudioMagicMomentDurationTracksSeededDuration() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-seed-audio-magic",
            "--ui-test-seed-audio-magic-duration=242",
        ])
        self.openStandaloneOnThisPhoneBrowse(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 10))
        let duration = app.staticTexts["magicMoment.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.label, "4m 2s")
    }

    @MainActor
    func testAudioEnrollmentPermissionDeniedDoesNotShowMagicMoment() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-reset-on-this-phone",
            "--ui-test-reset-audio-l5",
            "--ui-test-observer-permission-denied",
        ])

        self.tapDayHomeSourcesEntry(in: app)
        let audioRow = app.buttons["source.row.audio"]
        XCTAssertTrue(audioRow.waitForExistence(timeout: 5))
        audioRow.tap()

        let turnOnAudio = app.buttons["turn on audio"]
        XCTAssertTrue(turnOnAudio.waitForExistence(timeout: 5))
        turnOnAudio.tap()
        XCTAssertTrue(app.staticTexts["microphone access is required to take in audio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["turn on audio"].exists)

        self.dismissPresentedSheet(in: app, untilMissingElementID: "audioEnrollment.value")
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSeededOnThisPhoneSummaryHidesNeedsAttentionBanner() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)
        let needsAttention = app.descendants(matching: .any)["onThisPhone.status.needsAttention"]

        XCTAssertFalse(needsAttention.waitForExistence(timeout: 2))
    }

    @MainActor
    func testSeededOnThisPhoneDropGuardrailShowsSnackbar() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)
        let row = self.seedAudioRow(in: app)
        let surface = app.descendants(matching: .any)["onThisPhone.surface"]
        self.scrollToElement(row, in: surface)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seed mobile audio row")
        let rowID = row.identifier
        let exactRow = app.descendants(matching: .any)[rowID]
        row.tap()

        let dropButton = app.buttons["onThisPhone.drop.button"]
        XCTAssertTrue(dropButton.waitForExistence(timeout: 5), rowID)
        dropButton.tap()
        XCTAssertTrue(app.staticTexts["drop this from this device?"].waitForExistence(timeout: 5), rowID)

        let confirmButtons = app.buttons.matching(identifier: "onThisPhone.drop.confirm")
        let confirmButton = confirmButtons.firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), rowID)
        let actionableConfirmButton = confirmButtons.count > 1
            ? confirmButtons.element(boundBy: 1)
            : confirmButton
        actionableConfirmButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.drop.snackbar"].waitForExistence(timeout: 5), rowID)
        XCTAssertTrue(app.staticTexts["dropped “1m 15s of audio”."].waitForExistence(timeout: 5), rowID)
        XCTAssertTrue(exactRow.waitForNonExistence(timeout: 2), rowID)
    }

    @MainActor
    func testSeededOnThisPhoneSwipeToDropThenUndo() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)
        let row = self.seedAudioRow(in: app)
        let surface = app.descendants(matching: .any)["onThisPhone.surface"]
        self.scrollToElement(row, in: surface)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seed mobile audio row")
        let rowID = row.identifier
        let exactRow = app.descendants(matching: .any)[rowID]

        var attempts = 0
        while row.frame.maxY > surface.frame.maxY - 8 && attempts < 3 {
            surface.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(row.isHittable, rowID)

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        )
        let confirmTitle = app.staticTexts["drop this from this device?"]
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
        XCTAssertTrue(exactRow.waitForNonExistence(timeout: 0.5), rowID)

        let undoButton = app.descendants(matching: .any)["onThisPhone.drop.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5), rowID)
        undoButton.tap()

        XCTAssertTrue(exactRow.waitForExistence(timeout: 3), rowID)
        XCTAssertFalse(app.descendants(matching: .any)["onThisPhone.drop.snackbar"].waitForExistence(timeout: 2), rowID)
    }

    @MainActor
    func testOnThisPhoneNotBackedUpNudgeOpensConnectSheet() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-on-this-phone"])
        self.openStandaloneOnThisPhoneBrowse(in: app)

        XCTAssertTrue(app.staticTexts["onThisPhone.notBackedUp"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "onThisPhone.notBackedUp").count, 1)
        app.buttons["onThisPhone.connectJournal"].tap()
        XCTAssertTrue(app.navigationBars["connect a journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectJournal.ownJournal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["askPreview.sheet"].exists)
    }

    @MainActor
    func testMagicMomentSecondaryButtonOpensConnectSheetDirectly() {
        let app = self.launchNoJournalApp(extraArguments: ["--ui-test-seed-audio-magic"])
        self.openStandaloneOnThisPhoneBrowse(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["magicMoment.card"].waitForExistence(timeout: 10))
        app.buttons["magicMoment.connectJournal"].tap()
        XCTAssertTrue(app.navigationBars["connect a journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectJournal.ownJournal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["askPreview.sheet"].exists)
    }

    @MainActor
    func testAgedBacklogNudgeDismissalPersistsAcrossSeededLaunches() {
        let app = self.launchNoJournalApp(extraArguments: [
            "--ui-test-seed-aged-backlog",
            "--ui-test-reset-nudge-dismissal",
        ])
        self.openStandaloneOnThisPhoneBrowse(in: app)
        let text = "51 memories are on this device. connect a journal whenever you're ready."

        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10))
        app.buttons["onThisPhone.agedBacklog.dismiss"].tap()
        XCTAssertFalse(app.staticTexts["onThisPhone.agedBacklog"].waitForExistence(timeout: 2))

        app.terminate()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal", "--ui-test-seed-aged-backlog"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)
        self.openStandaloneOnThisPhoneBrowse(in: app)
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
        self.assertDayHomeRoot(in: app)
        return app
    }

    func assertDayHomeRoot(in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
    }

    func dismissPresentedSheet(in app: XCUIApplication, untilMissingElementID missingElementID: String) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        top.press(forDuration: 0.1, thenDragTo: bottom)
        XCTAssertTrue(app.descendants(matching: .any)[missingElementID].waitForNonExistence(timeout: 5))
    }

    func seedAudioRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "onThisPhone.row.transfer:mobile-segment:",
            ":audio"
        )).firstMatch
    }

    func scrollToElement(_ element: XCUIElement, in surface: XCUIElement) {
        if element.waitForExistence(timeout: 1) {
            return
        }
        for _ in 0..<5 {
            surface.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return
            }
        }
    }

    func assertSinglePairFlowMarker(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let markerText = "scan your pairing code"
        XCTAssertTrue(app.staticTexts[markerText].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", markerText)).count,
            1,
            file: file,
            line: line
        )
    }
}
