// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

@MainActor
extension XCTestCase {
    func openStandaloneOnThisPhoneBrowse(in app: XCUIApplication) {
        let importEntry = app.buttons["dayHome.importEntry"]
        XCTAssertTrue(importEntry.waitForExistence(timeout: 10))
        if !importEntry.isHittable {
            app.swipeUp()
        }
        importEntry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 5))
        let onThisDevice = app.buttons["import.onThisDeviceEntry"]
        XCTAssertTrue(onThisDevice.waitForExistence(timeout: 5))
        onThisDevice.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onThisPhone.surface"].waitForExistence(timeout: 5))
    }

    func tapDayHomeSourcesEntry(in app: XCUIApplication) {
        let sources = app.buttons["dayHome.sourcesEntry"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        if !sources.isHittable {
            app.swipeUp()
        }
        sources.tap()
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
