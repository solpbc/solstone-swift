// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class SmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    
    @MainActor
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
