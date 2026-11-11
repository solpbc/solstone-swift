// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

@MainActor
extension XCTestCase {
    func openStandaloneOnThisPhoneBrowse(in app: XCUIApplication) {
        self.tapDayHomeImportEntry(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 5))
        let onThisDevice = app.buttons["import.onThisDeviceEntry"]
        XCTAssertTrue(onThisDevice.waitForExistence(timeout: 5))
        onThisDevice.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 5))
    }

    /// The screenshots tile lengthens the deck, so the import tile can sit under the journal bar
    /// while still reporting itself hittable. Scroll until its frame is in the content area.
    func tapDayHomeImportEntry(in app: XCUIApplication) {
        let entry = app.buttons["dayHome.importEntry"]
        let surface = app.scrollViews["dayHome.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        // The deck is a lazy grid. A tile below the fold is not in the tree until
        // it scrolls near the viewport, and one that has just appeared can still
        // report itself hittable while its center is under the journal bar.
        for _ in 0..<12 {
            if entry.exists {
                let footer = app.buttons["dayHome.journalSetup"].exists
                    ? app.buttons["dayHome.journalSetup"] : app.buttons["dayHome.openInJournal"]
                let bottom = footer.exists ? footer.frame.minY : app.frame.maxY - 34
                let nav = app.navigationBars.firstMatch
                let top = nav.exists ? nav.frame.maxY : app.frame.minY
                if entry.isHittable, entry.frame.minY >= top, entry.frame.maxY <= bottom {
                    entry.tap()
                    return
                }
            }
            surface.swipeUp()
        }
        XCTFail("import tile never became visible above the journal bar")
    }

    func tapDayHomeSourcesEntry(in app: XCUIApplication) {
        let sources = app.buttons["dayHome.sourcesEntry"]
        let surface = app.scrollViews["dayHome.surface"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        // SwiftUI can report this below-fold tile as hittable while its center
        // is underneath the journal bar. Scroll it into the actual content area
        // before tapping, including when the deck grows or type is enlarged.
        for _ in 0..<12 {
            let footer = app.buttons["dayHome.journalSetup"].exists
                ? app.buttons["dayHome.journalSetup"] : app.buttons["dayHome.openInJournal"]
            let bottom = footer.exists ? footer.frame.minY : app.frame.maxY - 34
            let nav = app.navigationBars.firstMatch
            let top = nav.exists ? nav.frame.maxY : app.frame.minY
            if sources.isHittable, sources.frame.minY >= top,
               sources.frame.maxY <= bottom {
                sources.tap()
                return
            }
            surface.swipeUp()
        }
        XCTFail("add more tile never became visible above the journal bar")
    }

    func assertDayHomeGreeting(in app: XCUIApplication) {
        let greetings = ["good morning", "good afternoon", "good evening"]
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        if greetings.contains(bar.identifier) {
            return
        }
        let predicate = NSPredicate(format: "label IN %@", greetings)
        let navTitle = app.navigationBars.staticTexts.matching(predicate).firstMatch
        if navTitle.waitForExistence(timeout: 2) {
            XCTAssertTrue(greetings.contains(navTitle.label), navTitle.label)
            return
        }
        let windowTitle = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(windowTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(greetings.contains(windowTitle.label), windowTitle.label)
    }
}
