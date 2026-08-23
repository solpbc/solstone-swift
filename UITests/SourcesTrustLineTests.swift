// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class SourcesTrustLineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testNoJournalSourcesShowsSimplifiedSheet() {
        let app = self.launch(arguments: ["--ui-test", "--ui-test-no-journal"])
        self.openSources(in: app)
        self.assertSimplifiedSourcesSheet(in: app)
    }

    @MainActor
    func testConfiguredOfflineSourcesShowsSimplifiedSheet() {
        let app = self.launch(arguments: ["--ui-test", "--ui-test-shell-disconnected"])
        self.openSources(in: app)
        self.assertSimplifiedSourcesSheet(in: app)
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSources(in app: XCUIApplication) {
        let sourcesEntry = app.buttons["dayHome.sourcesEntry"]
        XCTAssertTrue(sourcesEntry.waitForExistence(timeout: 10))
        if !sourcesEntry.isHittable {
            app.swipeUp()
        }
        sourcesEntry.tap()
    }

    @MainActor
    private func assertSimplifiedSourcesSheet(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["source.row.audio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["source.row.location"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["source.row.share-sheet"].exists)
        XCTAssertFalse(app.buttons["sources.connectBanner"].exists)
        XCTAssertFalse(app.staticTexts["sources.trustLine"].exists)
        XCTAssertFalse(app.staticTexts["nothing is on right now"].exists)
    }
}
