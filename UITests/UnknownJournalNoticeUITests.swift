// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// The notice in the status pane: a row per place beside the connection's own state, each with its
/// own expand, both marks named to VoiceOver, and pair again only inside the detail.
///
/// Extract the renders after a run:
///   xcrun xcresulttool export attachments --path <result bundle> --output-path /tmp/shots
final class UnknownJournalNoticeUITests: XCTestCase {
    private let direct = "shell.pane.status.unknownJournal.192.168.4.63:7657"
    private let relay = "shell.pane.status.unknownJournal.relay"

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // A row's button and its text carry the same identifier.
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < 6 {
            app.swipeUp()
            tries += 1
        }
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Reset: the pill is asserted against caught up, and an earlier test's items can outlive it.
        app.launchArguments = [
            "--ui-test", "--ui-test-journal-mark", "--ui-test-seed-unknown-journal", "--ui-test-reset-on-this-phone",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(self.element("dayHome.surface", in: app).waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    func testTheNoticeIsAdditiveAndComparesBothMarks() throws {
        let app = self.launch()
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone sheet is the phone lane's; the pane is the same view")

        // The pill has no idea. It reads as it would with no sighting at all.
        XCTAssertTrue(self.element("dayHome.statusPill.state.caughtUp", in: app).waitForExistence(timeout: 20))
        self.attach(app, "00-home-pill-unchanged")

        app.buttons["dayHome.statusPill"].tap()
        XCTAssertTrue(self.element("shell.pane.status.heading", in: app).waitForExistence(timeout: 10))
        let directRow = self.element(self.direct, in: app)
        let relayRow = self.element(self.relay, in: app)
        self.scroll(to: relayRow, in: app)
        XCTAssertTrue(directRow.exists, "one row per place, never a summary")
        XCTAssertTrue(relayRow.exists, "one row per place, never a summary")
        XCTAssertFalse(self.element("\(self.direct).pairAgain", in: app).exists, "pair again only inside the detail")
        XCTAssertFalse(self.element("\(self.relay).pairAgain", in: app).exists, "pair again only inside the detail")
        self.attach(app, "01-status-rows")

        directRow.tap()
        let whatAnswered = self.element("\(self.direct).whatAnswered", in: app)
        let yourJournal = self.element("\(self.direct).yourJournal", in: app)
        self.scroll(to: yourJournal, in: app)
        XCTAssertTrue(whatAnswered.waitForExistence(timeout: 10))
        XCTAssertTrue(yourJournal.waitForExistence(timeout: 10))
        XCTAssertTrue(self.element("\(self.direct).pairAgain", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(self.element("\(self.relay).pairAgain", in: app).exists, "each row has its own expand")
        self.attach(app, "02-status-direct-detail")

        // Both marks are named and spoken, and they don't read as each other.
        XCTAssertFalse(whatAnswered.label.isEmpty)
        XCTAssertFalse(yourJournal.label.isEmpty)
        XCTAssertNotEqual(whatAnswered.label, yourJournal.label)
        let claimed = try XCTUnwrap(whatAnswered.value as? String)
        let own = try XCTUnwrap(yourJournal.value as? String)
        XCTAssertFalse(claimed.isEmpty)
        XCTAssertTrue(own.contains("afoot"), "your journal speaks the seeded mark, got \(own)")
        XCTAssertFalse(claimed.contains("afoot"), "what answered speaks its own mark, got \(claimed)")

        self.scroll(to: relayRow, in: app)
        relayRow.tap()
        let slot = self.element("\(self.relay).whatAnswered", in: app)
        self.scroll(to: self.element("\(self.relay).yourJournal", in: app), in: app)
        XCTAssertTrue(slot.waitForExistence(timeout: 10))
        self.attach(app, "03-status-relay-detail")

        // The no-identity slot has a spoken name of its own, not a mark's and not your journal's.
        XCTAssertFalse(slot.label.isEmpty)
        let slotValue = try XCTUnwrap(slot.value as? String)
        XCTAssertFalse(slotValue.isEmpty)
        XCTAssertNotEqual(slotValue, own)
        XCTAssertFalse(slotValue.contains("your journal"), "the slot is not the owner's journal, got \(slotValue)")

        // Still additive with the pane open and the detail expanded.
        XCTAssertTrue(self.element("shell.pane.status.leadState.caughtUp", in: app).exists)
    }

    @MainActor
    func testThePaneKeepsTheNoticeWhileTheJournalIsStalled() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test", "--ui-test-journal-mark", "--ui-test-seed-unknown-journal",
            "--ui-test-stall=stalled", "--ui-test-open-pane=status", "--ui-test-seed-screen-backlog",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(self.element("shell.pane.status.heading", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(self.element("shell.pane.status.leadState.stalled", in: app).waitForExistence(timeout: 20))
        let row = self.element(self.direct, in: app)
        self.scroll(to: row, in: app)
        XCTAssertTrue(row.exists)
        self.attach(app, "04-status-stalled-with-notice")
    }
}
