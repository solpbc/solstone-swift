// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// Setup's second step asks which sites, and the answer picks the panel under it.
final class SafariSetUpChoiceUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ mode: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test",
            "--ui-test-no-journal",
            "--ui-test-safari=\(mode)",
            "--ui-test-open-pane=source:safari",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad opens sources in the split view")
        XCTAssertTrue(app.descendants(matching: .any)["safari.page.step2"].waitForExistence(timeout: 15),
                      "Safari setup never showed in \(mode)")
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func assertNoAnswer(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let everySite = app.buttons["safari.page.choose.everySite"]
        let oneAtATime = app.buttons["safari.page.choose.oneAtATime"]
        XCTAssertTrue(everySite.waitForExistence(timeout: 5), "no every-site button", file: file, line: line)
        XCTAssertTrue(oneAtATime.exists, "no one-at-a-time button", file: file, line: line)
        XCTAssertFalse(everySite.isSelected, "every site reports selected", file: file, line: line)
        XCTAssertFalse(oneAtATime.isSelected, "one at a time reports selected", file: file, line: line)
        XCTAssertFalse(self.element(app, "safari.page.everySite").exists, "every-site panel shows", file: file, line: line)
        XCTAssertFalse(self.element(app, "safari.page.oneAtATime.otherWebsites").exists, "one-at-a-time panel shows",
                       file: file, line: line)
        XCTAssertFalse(app.textFields["safari.page.siteField"].exists, "site field shows", file: file, line: line)
    }

    // 1
    @MainActor
    func testAStoredChoiceDoesNotCarryIntoAddSite() throws {
        let chosen = try self.launch("chooseEverySite")
        XCTAssertTrue(self.element(chosen, "safari.page.everySite").waitForExistence(timeout: 5), "the seeded answer never showed")
        chosen.terminate()

        let app = try self.launch("addSite")
        self.assertNoAnswer(app)
    }

    // 2
    @MainActor
    func testTappingAnAnswerShowsItsPanelAndTheOtherSwapsIt() throws {
        let app = try self.launch("addSite")
        let everySite = app.buttons["safari.page.choose.everySite"]
        let oneAtATime = app.buttons["safari.page.choose.oneAtATime"]
        let panel = self.element(app, "safari.page.everySite")
        let field = app.textFields["safari.page.siteField"]

        XCTAssertTrue(everySite.waitForExistence(timeout: 5))
        everySite.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "tapping every site showed no panel")
        XCTAssertTrue(everySite.isSelected, "every site doesn't report selected")
        XCTAssertFalse(oneAtATime.isSelected)
        XCTAssertTrue(app.buttons["safari.page.everySite.openSettings"].exists, "no open Settings in the panel")
        XCTAssertFalse(field.exists, "the site field shows under every site")

        oneAtATime.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tapping one at a time showed no field")
        XCTAssertTrue(oneAtATime.isSelected, "one at a time doesn't report selected")
        XCTAssertFalse(everySite.isSelected, "every site still reports selected")
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "the every-site panel stayed")
    }

    // 3
    @MainActor
    func testAStoredChoiceIsReadAndAnUnknownOneIsNoChoice() throws {
        let chosen = try self.launch("chooseEverySite")
        XCTAssertTrue(self.element(chosen, "safari.page.everySite").waitForExistence(timeout: 5), "the stored answer wasn't read")
        XCTAssertTrue(chosen.buttons["safari.page.choose.everySite"].isSelected)
        XCTAssertFalse(chosen.buttons["safari.page.choose.oneAtATime"].isSelected)
        chosen.terminate()

        let app = try self.launch("chooseGarbage")
        self.assertNoAnswer(app)
    }

    // 3a
    @MainActor
    func testOneAtATimeSaysWhatOtherWebsitesMeansAboveTheField() throws {
        let app = try self.launch("chooseOneAtATime")
        let line = self.element(app, "safari.page.oneAtATime.otherWebsites")
        let field = app.textFields["safari.page.siteField"]
        XCTAssertTrue(line.waitForExistence(timeout: 5), "no Other Websites line")
        XCTAssertTrue(field.exists, "no site field")
        XCTAssertLessThanOrEqual(line.frame.maxY, field.frame.minY, "the Other Websites line isn't above the field")
        XCTAssertFalse(self.element(app, "safari.page.everySite").exists)
    }

    // 4, seeded to fail
    @MainActor
    func testOpenSettingsFailingInThePanelShowsTheWayByHand() throws {
        let app = try self.launch("chooseEverySite")
        let open = app.buttons["safari.page.everySite.openSettings"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(self.element(app, "safari.page.everySite.body").exists)
        open.tap()
        XCTAssertTrue(self.element(app, "safari.page.everySite.byHand").waitForExistence(timeout: 5), "no by-hand line")
        XCTAssertFalse(open.exists, "open Settings stayed")
        XCTAssertFalse(self.element(app, "safari.page.everySite.body").exists, "the explanation stayed")
        XCTAssertTrue(self.element(app, "safari.page.everySite.next").exists, "the next line went")
    }

    // 4, seeded to succeed
    @MainActor
    func testOpenSettingsInThePanelGoesToSettingsOnce() throws {
        let app = try self.launch("chooseEverySiteOpens")
        let open = app.buttons["safari.page.everySite.openSettings"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(self.element(app, "safari.page.openSettings.calls.0").exists)
        open.tap()
        XCTAssertTrue(self.element(app, "safari.page.openSettings.calls.1").waitForExistence(timeout: 5), "no call recorded")
        XCTAssertFalse(self.element(app, "safari.page.openSettings.calls.2").exists, "more than one call recorded")
        XCTAssertTrue(open.exists, "open Settings went")
        XCTAssertTrue(self.element(app, "safari.page.everySite.body").exists, "the explanation went")
        XCTAssertFalse(self.element(app, "safari.page.everySite.byHand").exists)
    }

    // 4, [check]: step 1 keeps today's body where Settings can't be opened.
    @MainActor
    func testStepOneKeepsItsBodyWhereSettingsCantBeOpened() throws {
        let app = try self.launch("setUp")
        let withLink = "flip Allow Extension in Settings. to put every site in your journal, also set Other Websites to Allow, further down the same page. then come back here."
        let byHand = "one switch in Settings. flip it, then come back here."
        let text = { (label: String) in app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch }
        let open = app.buttons["safari.openSettings"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(text(withLink).exists, "step 1 doesn't name Other Websites")
        open.tap()
        XCTAssertTrue(self.element(app, "safari.page.settingsByHand").waitForExistence(timeout: 5))
        XCTAssertTrue(text(byHand).exists, "step 1 lost today's body by hand")
        XCTAssertFalse(text(withLink).exists, "step 1 still says the same page")
    }
}
