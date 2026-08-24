// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// The iPad split shape and the two navigation channels.
///
/// `make ci` and `make ci-ipad` run the identical test set, so every assertion
/// here is guarded on the window shape rather than assumed. The phone lane skips
/// them; the collapse test is the mirror image and skips on iPad.
final class PadSplitShellUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
    }

    private func launchPad(_ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipUnless(self.isPadShapedWindow(app), "the split shape is the iPad lane's")
        return app
    }

    private func deck(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["dayHome.surface"]
    }

    /// The deck column is pinned narrow, so a tile can sit below the fold.
    private func tapDeck(_ identifier: String, in app: XCUIApplication) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) missing")
        for _ in 0..<3 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(identifier) not hittable")
        element.tap()
    }

    // MARK: - AC1: the shape

    /// The deck is the leading column in every state: at rest, after a deck tap,
    /// and after a push inside the pane.
    @MainActor
    func testDeckLeadsInEveryState() throws {
        let app = try self.launchPad()
        XCTAssertTrue(self.deck(in: app).waitForExistence(timeout: 10))

        self.tapDeck("dayHome.tile.audio", in: app)
        XCTAssertTrue(app.navigationBars["audio"].waitForExistence(timeout: 10))
        XCTAssertTrue(self.deck(in: app).exists, "deck left the leading column after a deck tap")

        self.tapDeck("dayHome.importEntry", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(self.deck(in: app).exists, "deck left the leading column after a second tap")
    }

    /// AC1 shot: the two-column split with the deck leading, portrait and landscape.
    @MainActor
    func testCaptureSplitShape() throws {
        let app = try self.launchPad()
        XCTAssertTrue(self.deck(in: app).waitForExistence(timeout: 10))
        self.attach(app, "ac1-split-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(self.deck(in: app).waitForExistence(timeout: 10))
        self.attach(app, "ac1-split-landscape")
    }

    // MARK: - AC2: replace from the deck, push inside the pane

    /// Both halves. The pane's root changes AND the deck is still showing its
    /// grid, which is what falsifies a sidebar push.
    @MainActor
    func testDeckTapReplacesPaneRootAndLeavesTheDeckShowing() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.tile.audio", in: app)
        XCTAssertTrue(app.navigationBars["audio"].waitForExistence(timeout: 10))

        XCTAssertTrue(
            app.buttons["dayHome.tile.location"].waitForExistence(timeout: 5),
            "deck grid gone after a deck tap"
        )
        self.tapDeck("dayHome.tile.location", in: app)

        // The pane root was replaced, not pushed onto: the previous destination is
        // gone rather than sitting underneath a back button.
        XCTAssertTrue(app.navigationBars["location"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["audio"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(self.deck(in: app).exists)
        self.attach(app, "ac2-deck-tap-replaced-pane-root")
    }

    /// A link inside the pane pushes, so the pane keeps a back button while the
    /// deck stays put.
    @MainActor
    func testInPaneLinkPushes() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.importEntry", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10)
        )

        let onThisDevice = app.buttons["on this device"]
        XCTAssertTrue(onThisDevice.waitForExistence(timeout: 10), "in-pane link missing")
        onThisDevice.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(self.deck(in: app).exists, "deck left the leading column on an in-pane push")

        // Pushed, not replaced: it pops back to the pane root.
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10)
        )
    }

    // MARK: - AC3: the four fixed openers

    @MainActor
    func testStatusOpenerSelectsThePaneRoot() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.statusPill", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(self.deck(in: app).exists)
    }

    @MainActor
    func testYourSolstoneOpenerSelectsThePaneRoot() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.yourSolstoneEntry", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(self.deck(in: app).exists)
    }

    @MainActor
    func testSourcesOpenerSelectsThePaneRoot() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.sourcesEntry", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.addMore"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(self.deck(in: app).exists)
    }

    /// The paired branch of the journal pill.
    @MainActor
    func testJournalOpenerSelectsThePaneRoot() throws {
        let app = try self.launchPad(["--ui-test-journal-mark"])
        let opener = app.buttons["dayHome.openInJournal"]
        guard opener.waitForExistence(timeout: 10) else {
            throw XCTSkip("this launch state is not paired and online, so the journal door is absent")
        }
        opener.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.journal.heading"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(self.deck(in: app).exists)
    }

    /// The unpaired branch. It reaches journal setup as the pane root rather than
    /// the phone shell's sheet.
    @MainActor
    func testUnpairedJournalOpenerSelectsJournalSetup() throws {
        let app = try self.launchPad(["--ui-test-no-journal"])
        self.tapDeck("dayHome.journalSetup", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.journalSetup.heading"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(self.deck(in: app).exists)
    }

    @MainActor
    func testShelfRowsShowDedicatedPaneHeadings() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.yourSolstoneEntry", in: app)

        let rows = [
            ("shell.pane.shelf.journal", "shell.pane.shelfJournal.heading"),
            ("shell.pane.shelf.thisDevice", "shell.pane.shelfThisDevice.heading"),
            ("shell.pane.shelf.notifications", "shell.pane.shelfNotifications.heading"),
            ("shell.pane.shelf.help", "shell.pane.shelfHelp.heading"),
            ("shell.pane.shelf.about", "shell.pane.shelfAbout.heading"),
        ]
        for row in rows {
            let button = app.buttons[row.0]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(row.0) missing")
            button.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)[row.1].waitForExistence(timeout: 10),
                "\(row.1) missing"
            )
            self.popPane(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10))
        }
    }

    @MainActor
    func testStatusPanePushesDiagnosticsAndProblemReports() throws {
        let app = try self.launchPad(["--ui-test-open-pane=status"])
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 10))

        let diagnostics = app.buttons["shell.pane.status.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["diagnostics"].waitForExistence(timeout: 10))
        self.popPane(in: app)

        let reports = app.buttons["shell.pane.status.problemReports"]
        XCTAssertTrue(reports.waitForExistence(timeout: 10))
        reports.tap()
        XCTAssertTrue(app.navigationBars["problem reports"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testShelfRowPushesAndPopsInsidePane() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.yourSolstoneEntry", in: app)
        let row = app.buttons["shell.pane.shelf.thisDevice"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelfThisDevice.heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(self.deck(in: app).exists)
        self.popPane(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testJournalSetupOwnJournalPushesPairFlow() throws {
        let app = try self.launchPad(["--ui-test-no-journal"])
        self.tapDeck("dayHome.journalSetup", in: app)
        let ownJournal = app.buttons["journalLives.ownJournal"]
        XCTAssertTrue(ownJournal.waitForExistence(timeout: 10))
        ownJournal.tap()
        let marker = app.staticTexts["scan your pairing code"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "scan your pairing code")).count, 1)
    }

    @MainActor
    func testAddMoreSelectionPushesSourceDetail() throws {
        let app = try self.launchPad()
        self.tapDeck("dayHome.sourcesEntry", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.addMore"].waitForExistence(timeout: 10))
        let audio = app.buttons["source.row.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        audio.tap()
        XCTAssertTrue(app.navigationBars["audio"].waitForExistence(timeout: 10))
        XCTAssertTrue(self.deck(in: app).exists)
    }

    @MainActor
    func testCaptureRewiredPaneShots() throws {
        let status = try self.launchPad(["--ui-test-open-pane=status"])
        XCTAssertTrue(status.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 10))
        self.attach(status, "l33-ipad-status-root")
        status.buttons["shell.pane.status.diagnostics"].tap()
        XCTAssertTrue(status.navigationBars["diagnostics"].waitForExistence(timeout: 10))
        self.attach(status, "l33-ipad-status-diagnostics")
        self.popPane(in: status)
        status.buttons["shell.pane.status.problemReports"].tap()
        XCTAssertTrue(status.navigationBars["problem reports"].waitForExistence(timeout: 10))
        self.attach(status, "l33-ipad-status-problem-reports")
        status.terminate()

        let journal = try self.launchPad(["--ui-test-journal-mark", "--ui-test-open-pane=journal"])
        XCTAssertTrue(journal.descendants(matching: .any)["shell.pane.journal.heading"].waitForExistence(timeout: 10))
        self.attach(journal, "l33-ipad-journal-root")
        journal.terminate()

        let setup = try self.launchPad(["--ui-test-no-journal"])
        self.tapDeck("dayHome.journalSetup", in: setup)
        XCTAssertTrue(setup.descendants(matching: .any)["shell.pane.journalSetup.heading"].waitForExistence(timeout: 10))
        self.attach(setup, "l33-ipad-journal-setup")
        setup.buttons["journalLives.ownJournal"].tap()
        XCTAssertTrue(setup.staticTexts["scan your pairing code"].waitForExistence(timeout: 10))
        self.attach(setup, "l33-ipad-pair-flow")
        setup.terminate()

        let shelf = try self.launchPad(["--ui-test-open-pane=shelf"])
        XCTAssertTrue(shelf.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10))
        self.attach(shelf, "l33-ipad-shelf-root")
        self.captureShelfLeaf(
            in: shelf,
            row: "shell.pane.shelf.journal",
            heading: "shell.pane.shelfJournal.heading",
            shot: "l33-ipad-shelf-journal"
        )
        self.captureShelfLeaf(
            in: shelf,
            row: "shell.pane.shelf.thisDevice",
            heading: "shell.pane.shelfThisDevice.heading",
            shot: "l33-ipad-shelf-this-device"
        )
        self.captureShelfLeaf(
            in: shelf,
            row: "shell.pane.shelf.notifications",
            heading: "shell.pane.shelfNotifications.heading",
            shot: "l33-ipad-shelf-notifications"
        )
        self.captureShelfLeaf(
            in: shelf,
            row: "shell.pane.shelf.help",
            heading: "shell.pane.shelfHelp.heading",
            shot: "l33-ipad-shelf-help"
        )
        self.captureShelfLeaf(
            in: shelf,
            row: "shell.pane.shelf.about",
            heading: "shell.pane.shelfAbout.heading",
            shot: "l33-ipad-shelf-about"
        )
    }

    // MARK: - AC8: the collapsed shell is the phone shell

    /// The mirror image: at compact width the shell rests on the deck, and the
    /// phone shell's own presentation is what answers the openers.
    @MainActor
    func testCompactWidthRestsOnTheDeck() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the collapsed shell is the phone lane's")

        // The deck, not the pane, is what a collapsed window opens on.
        XCTAssertTrue(self.deck(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["shell.hitStrip"].waitForExistence(timeout: 5))
        self.attach(app, "ac8-collapsed-deck")

        // The shelf is still the phone shell's overlay with its own dismiss.
        let opener = app.buttons["dayHome.yourSolstoneEntry"]
        XCTAssertTrue(opener.waitForExistence(timeout: 10))
        opener.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["done"].waitForExistence(timeout: 5))
    }

    /// The hit strip is a phone-shell edge gesture: on iPad the leading edge
    /// belongs to the system sidebar swipe.
    @MainActor
    func testHitStripIsAbsentOnPad() throws {
        let app = try self.launchPad()
        XCTAssertTrue(self.deck(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.descendants(matching: .any)["shell.hitStrip"].exists,
            "the leading edge belongs to the system sidebar swipe on iPad"
        )
    }

    @MainActor
    private func popPane(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
    }

    @MainActor
    private func captureShelfLeaf(
        in app: XCUIApplication,
        row: String,
        heading: String,
        shot: String
    ) {
        let button = app.buttons[row]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(row) missing")
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)[heading].waitForExistence(timeout: 10))
        self.attach(app, shot)
        self.popPane(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        self.add(shot)
    }
}
