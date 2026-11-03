// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// The answer screens of the pairing's mark question, seeded directly: no live journal can be made
/// to fail a read on cue. Each screenshot is kept so a reviewer can look at the owner's pixels.
final class PairFlowAnswerUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-mark-confirm"] + arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["pairFlow.title"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testCouldNotVerifyDrawsAMark() {
        let app = self.launch(["--ui-test-mark-could-not-verify"])
        XCTAssertTrue(app.descendants(matching: .any)["journalMark"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pairFlow.answer.cancel"].exists)
        self.attach(app, "could-not-verify")
    }

    @MainActor
    func testNoCommittedMarkDrawsAMark() {
        let app = self.launch(["--ui-test-mark-no-committed-mark"])
        XCTAssertTrue(app.descendants(matching: .any)["journalMark"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pairFlow.answer.cancel"].exists)
        self.attach(app, "no-committed-mark")
    }

    @MainActor
    func testMismatchResultRenders() {
        let app = self.launch(["--ui-test-mark-mismatch"])
        self.attach(app, "mismatch")
    }

    @MainActor
    func testRejectingShowsProgressThenSaysItDidNotFinish() {
        let app = self.launch(["--ui-test-mark-teardown-fails"])
        self.attach(app, "confirm")
        let reject = app.buttons["pairFlow.answer.mismatch"]
        XCTAssertTrue(reject.waitForExistence(timeout: 10))
        reject.tap()

        XCTAssertTrue(app.descendants(matching: .any)["pairFlow.teardown.progress"].waitForExistence(timeout: 5))
        XCTAssertFalse(reject.isEnabled)
        self.attach(app, "teardown-progress")

        XCTAssertTrue(app.descendants(matching: .any)["pairFlow.teardown.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(reject.isEnabled)
        self.attach(app, "teardown-failed")
    }

    @MainActor
    func testCancellingShowsProgressThenSaysItDidNotFinish() {
        let app = self.launch(["--ui-test-mark-could-not-verify", "--ui-test-mark-teardown-fails"])
        let cancel = app.buttons["pairFlow.answer.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()

        XCTAssertTrue(app.descendants(matching: .any)["pairFlow.teardown.progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["pairFlow.teardown.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(cancel.isEnabled)
    }
}
