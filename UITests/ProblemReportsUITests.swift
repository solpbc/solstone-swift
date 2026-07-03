// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class ProblemReportsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testOptedOutState() {
        let app = self.launchProblemReportsApp(seed: "opted-out")
        self.openMore(in: app)
        let toggle = app.switches["more.diagnostics.problemReports.toggle"]
        self.scrollToElement(toggle, in: app)
        XCTAssertTrue(toggle.exists)
        self.openProblemReports(in: app)

        XCTAssertTrue(app.otherElements["problemReports.empty.optedOut"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOptedInEmptyState() {
        let app = self.launchProblemReportsApp(seed: "opted-in-empty")
        self.openMore(in: app)
        self.openProblemReports(in: app)

        XCTAssertTrue(app.otherElements["problemReports.empty.enabled"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPopulatedListState() {
        let app = self.launchProblemReportsApp(seed: "populated-list")
        self.openMore(in: app)
        let row = app.buttons["more.diagnostics.problemReports"]
        self.scrollToElement(row, in: app)
        XCTAssertTrue(row.exists)
        row.tap()

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "problemReports.report.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["problemReports.shareAll"].exists)
        XCTAssertTrue(app.buttons["problemReports.deleteAll"].exists)
    }

    @MainActor
    func testDetailState() {
        let app = self.launchProblemReportsApp(seed: "detail")
        self.openMore(in: app)
        self.openProblemReports(in: app)

        let report = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "problemReports.report.")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        report.tap()

        XCTAssertTrue(app.buttons["problemReports.share"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["problemReports.delete"].exists)
    }
}

@MainActor
private extension ProblemReportsUITests {
    func launchProblemReportsApp(seed: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-seed-problem-reports=\(seed)",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    func openMore(in app: XCUIApplication) {
        let entry = app.buttons["dayHome.yourSolstoneEntry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["your solstone"].waitForExistence(timeout: 10))
    }

    func openProblemReports(in app: XCUIApplication) {
        let row = app.buttons["more.diagnostics.problemReports"]
        self.scrollToElement(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["problem reports"].waitForExistence(timeout: 10))
    }

    func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 2) {
            return
        }
        let scrollContainer = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.scrollViews.firstMatch
        XCTAssertTrue(scrollContainer.waitForExistence(timeout: 10))

        let start = scrollContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let end = scrollContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        for _ in 1...10 {
            start.press(forDuration: 0.05, thenDragTo: end)
            if element.waitForExistence(timeout: 1) {
                return
            }
        }
    }
}
