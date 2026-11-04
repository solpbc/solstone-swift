// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// The row in about solstone, and the pane it opens. The renders are the check on the file's text.
///
/// Extract the renders after a run:
///   xcrun xcresulttool export attachments --path <result bundle> --output-path /tmp/shots
final class LicensesPaneUITests: XCTestCase {
    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testAboutOpensTheNoticesFileAndItScrolls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-no-journal", "--ui-test-open-pane=shelfAbout"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelfAbout.heading"].waitForExistence(timeout: 20))

        let row = app.descendants(matching: .any).matching(identifier: "shell.pane.shelfAbout.licenses").firstMatch
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists)
        self.attach(app, "01-about-row")
        row.tap()

        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.licenses.heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["swift-crypto"].waitForExistence(timeout: 10), "a section's name, without its marker")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '#'")).count, 0)
        self.attach(app, "02-licenses-top")

        // A section in the middle: its licence text is the one with CRLF line endings upstream.
        let font = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reserved Font Name'")).firstMatch
        var pages = 0
        while !font.exists, pages < 40 {
            app.swipeUp(velocity: .fast)
            pages += 1
        }
        XCTAssertTrue(font.exists, "reached the font's licence after \(pages) swipes")
        self.attach(app, "03-licenses-font-section")

        // The last section, so the text is scrollable all the way down.
        let last = app.staticTexts["EFF Long Wordlist"]
        pages = 0
        while !last.exists, pages < 80 {
            app.swipeUp(velocity: .fast)
            pages += 1
        }
        XCTAssertTrue(last.exists, "reached the last section after \(pages) swipes")
        self.attach(app, "04-licenses-last-section")
    }
}
