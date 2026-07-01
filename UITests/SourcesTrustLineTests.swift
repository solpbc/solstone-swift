// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class SourcesTrustLineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testConfiguredOfflineSourcesShowsConfiguredTrustLineWithoutConnectBanner() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-shell-disconnected"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        let sourcesEntry = app.buttons["dayHome.sourcesEntry"]
        XCTAssertTrue(sourcesEntry.waitForExistence(timeout: 10))
        sourcesEntry.tap()

        let footer = app.staticTexts["sources.trustLine"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertEqual(footer.label, "syncs only to your journal — nowhere else")
        XCTAssertFalse(app.buttons["sources.connectBanner"].exists)
    }
}
