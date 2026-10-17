// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class PairLinkCameraUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Arrival stages a populated paste screen. Connecting remains an explicit owner action.
    @MainActor
    func testLinkArrivalShowsPrefilledPasteWithoutCamera() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-no-journal",
            "--ui-test-pair-link=https://go.solstone.app/p#0M0G86WY18004AGA0012P2G008P0M0025PGV5GYMWQV0E60H48SM8NB6EY4DXBDYXZ5FXENY04HMASW9NF6YY"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let field = app.descendants(matching: .any)["pairFlow.pasteField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["back"].exists)
        XCTAssertTrue((field.value as? String ?? "").hasPrefix("https://go.solstone.app/p#"))
        XCTAssertTrue(app.buttons["pair this device"].isEnabled)
        XCTAssertFalse(app.alerts.firstMatch.exists, "arrival must not request camera permission")
    }
}
