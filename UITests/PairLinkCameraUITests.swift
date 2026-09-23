// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class PairLinkCameraUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The camera scanner lives on the pairing screen, and on a phone its mount is what raises the
    /// camera prompt, so a link that is pairing must never show that screen. The simulator has no
    /// camera: a scanner that mounts there reports itself unavailable and flips the screen to paste,
    /// and the pasted-link controls then stay up for the rest of the attempt. Seeing the scan/paste
    /// chooser or the "scan a code instead" button while a link pairs means the pairing screen showed.
    /// The link names four unreachable private addresses: each candidate's dial is bounded at 5 s,
    /// so the attempt stays out for about 20 s, well past this test's window.
    @MainActor
    func testLinkPairingNeverShowsThePairingScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-pair-link=https://go.solstone.app/p#0M0G86WY18004AGA0012P2G008P0M0025PGV5GYMWQV0E60H48SM8NB6EY4DXBDYXZ5FXENY04HMASW9NF6YY"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(app.buttons["back"].waitForExistence(timeout: 10), "the pairing sheet never opened")

        let deadline = Date().addingTimeInterval(4)
        repeat {
            XCTAssertFalse(
                app.buttons["scan a code instead"].exists,
                "the pairing screen showed in paste mode while a link was pairing"
            )
            XCTAssertFalse(
                app.segmentedControls.buttons["paste"].exists,
                "the scan/paste chooser showed while a link was pairing"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
    }
}
