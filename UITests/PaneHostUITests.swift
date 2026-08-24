// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

nonisolated final class PaneHostUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testHitStripExistsOnlyOnRoot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))

        let strip = app.descendants(matching: .any)["shell.hitStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))

        let audio = app.buttons["dayHome.tile.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.tap()
        XCTAssertTrue(app.navigationBars["audio"].waitForExistence(timeout: 5))
        XCTAssertFalse(strip.exists)

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
    }

    @MainActor
    func testStatusPushOpensDiagnostics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=status"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(
            self.isPadShapedWindow(app),
            "the sheet detent this asserts is the phone shell's; iPad opens half-screen"
        )

        let pane = app.descendants(matching: .any)["shell.pane.status"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 5))
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let mediumValue = grabber.value as? String

        let diagnostics = app.descendants(matching: .any)["shell.pane.status.diagnostics"]
        self.scrollToElement(diagnostics, in: app)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.lifecycle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["diagnostics"].waitForExistence(timeout: 5))
        XCTAssertEqual(grabber.value as? String, "Expanded")

        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status.heading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["diagnostics"].exists)
        XCTAssertNotEqual(grabber.value as? String, "Expanded")
        XCTAssertEqual(grabber.value as? String, mediumValue)

        let reports = app.descendants(matching: .any)["shell.pane.status.problemReports"]
        self.scrollToElement(reports, in: app)
        XCTAssertTrue(reports.waitForExistence(timeout: 5))
        reports.tap()
        XCTAssertTrue(
            app.otherElements["problemReports.empty.optedOut"].waitForExistence(timeout: 10)
                || app.navigationBars["problem reports"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(grabber.value as? String, "Expanded")
    }

    @MainActor
    func testStatusDegradedWhenDisconnected() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-shell-disconnected",
            "--ui-test-open-pane=status",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")

        let degraded = app.descendants(matching: .any)["shell.pane.status.degraded"]
        XCTAssertTrue(degraded.waitForExistence(timeout: 10))
        XCTAssertTrue(degraded.label.contains("offline") || (degraded.value as? String)?.contains("offline") == true)
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.connected"].exists)
        XCTAssertNotEqual(degraded.label, "0")
        XCTAssertNotEqual(degraded.value as? String, "0")
    }

    @MainActor
    func testShelfPresentsFromOpener() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        let opener = app.buttons["dayHome.yourSolstoneEntry"]
        XCTAssertTrue(opener.waitForExistence(timeout: 10))
        opener.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["done"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testShelfLeavesTrailingDeckBand() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=shelf"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf"].waitForExistence(timeout: 10))
        let panel = app.descendants(matching: .any)["shell.pane.shelf.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let panelMaxX = panel.frame.maxX
        let windowMaxX = window.frame.maxX
        let margin = windowMaxX - panelMaxX
        XCTContext.runActivity(
            named: "shelf-panel panelMaxX=\(Self.pt(panelMaxX)) windowMaxX=\(Self.pt(windowMaxX)) margin=\(Self.pt(margin))"
        ) { _ in }
        // AC2 measures the leading panel, not the modal container. The container
        // includes the trailing dim and is full-window by design; asserting
        // against it would not prove the deck is visible trailing.
        XCTAssertGreaterThanOrEqual(margin, 24, "shelf panel maxX margin \(margin)")
    }

    @MainActor
    func testShelfHidesDeckFromAccessibilityTree() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=shelf"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf.heading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dayHome.statusPill"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["dayHome.tile.audio"].exists)
        app.buttons["done"].tap()
        XCTAssertTrue(app.buttons["dayHome.yourSolstoneEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.shelf"].exists)
    }

    @MainActor
    func testShelfPanelFillsWindowInLandscape() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=shelf"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(
            self.isPadShapedWindow(app),
            "ruling 7 is a compact-height rule; an iPad stays regular height in landscape"
        )
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf"].waitForExistence(timeout: 10))
        let panel = app.descendants(matching: .any)["shell.pane.shelf.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let panelFrame = panel.frame
        let windowFrame = window.frame
        XCTContext.runActivity(
            named: "ac8-shelf panel=\(Self.pt(panelFrame)) window=\(Self.pt(windowFrame))"
        ) { _ in }
        XCTAssertEqual(panelFrame.minX, windowFrame.minX, accuracy: 2)
        XCTAssertEqual(panelFrame.minY, windowFrame.minY, accuracy: 2)
        XCTAssertEqual(panelFrame.width, windowFrame.width, accuracy: 2)
        XCTAssertEqual(panelFrame.height, windowFrame.height, accuracy: 2)
    }

    @MainActor
    func testJournalPresentsInLandscape() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=journal"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.journal"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let pane = app.descendants(matching: .any)["shell.pane.journal"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTContext.runActivity(
            named: "ac8-journal pane=\(Self.pt(pane.frame)) window=\(Self.pt(window.frame))"
        ) { _ in }
    }

    @MainActor
    func testStatusPresentsInLandscape() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=status"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.status"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let pane = app.descendants(matching: .any)["shell.pane.status"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTContext.runActivity(
            named: "ac8-status pane=\(Self.pt(pane.frame)) window=\(Self.pt(window.frame))"
        ) { _ in }
    }

    @MainActor
    func testJournalPanePresentsFromOpener() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        let opener = app.buttons["dayHome.openInJournal"]
        XCTAssertTrue(opener.waitForExistence(timeout: 10))
        opener.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.journal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.journal.heading"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["done"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testJournalPaneRestsAboveDeck() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let tile = app.descendants(matching: .any)["dayHome.tile.audio"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        let windowFrame = window.frame
        let tileFrame = tile.frame

        let opener = app.buttons["dayHome.openInJournal"]
        XCTAssertTrue(opener.waitForExistence(timeout: 5))
        opener.tap()

        let pane = app.descendants(matching: .any)["shell.pane.journal"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        let paneFrame = pane.frame
        let margin = paneFrame.minY - windowFrame.minY
        let sliver = paneFrame.minY - tileFrame.minY
        let pill = app.buttons["dayHome.statusPill"]
        let shelf = app.buttons["dayHome.yourSolstoneEntry"]
        let tileAfter = app.descendants(matching: .any)["dayHome.tile.audio"]
        XCTContext.runActivity(
            named: "journal-rest window=\(Self.pt(windowFrame)) tile=\(Self.pt(tileFrame)) pane=\(Self.pt(paneFrame)) margin=\(Self.pt(margin)) sliver=\(Self.pt(sliver)) pill.exists=\(pill.exists) pill.hittable=\(pill.isHittable) shelf.exists=\(shelf.exists) shelf.hittable=\(shelf.isHittable) tile.exists=\(tileAfter.exists) tile.hittable=\(tileAfter.isHittable)"
        ) { _ in }

        XCTAssertGreaterThanOrEqual(margin, 24, "journal minY margin \(margin)")
        XCTAssertTrue(
            app.descendants(matching: .any)["dayHome.surface"].exists
                || pill.exists
                || shelf.exists
        )
    }

    @MainActor
    func testJournalPaneShowsRetryWhenDisconnected() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-no-journal",
            "--ui-test-open-pane=journal",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.journal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["try again"].waitForExistence(timeout: 5))
        let heading = app.descendants(matching: .any)["shell.pane.journal.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertNotEqual(heading.label, "journal")
    }

    @MainActor
    func testJournalPaneTitleUsesMarkWordsWhenSeeded() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test",
            "--ui-test-journal-mark",
            "--ui-test-open-pane=journal",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        let heading = app.descendants(matching: .any)["shell.pane.journal.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(heading.label.contains("afoot"), heading.label)
        XCTAssertTrue(heading.label.contains("unfixed"), heading.label)
    }

    @MainActor
    func testStatusConnectedTwinWhenUp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-open-pane=status"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")

        let connected = app.descendants(matching: .any)["shell.pane.status.connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["shell.pane.status.degraded"].exists)
        let value = (connected.value as? String) ?? connected.label
        XCTAssertTrue(
            value.contains("connected"),
            value
        )
        XCTAssertNotEqual(value, "0")
    }
}

@MainActor
private extension PaneHostUITests {
    static func pt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    static func pt(_ rect: CGRect) -> String {
        String(
            format: "(%.1f,%.1f %.1fx%.1f)",
            rect.minX,
            rect.minY,
            rect.width,
            rect.height
        )
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
