// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class PairingDeepLinkLaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPairURLLaunchPresentsPairFlow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--pair-url=https://go.solstone.app/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["pair your solstone"].waitForExistence(timeout: 10))

        let pairingError = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Pairing error:")
        ).firstMatch
        XCTAssertTrue(pairingError.waitForExistence(timeout: 30))
    }
}
