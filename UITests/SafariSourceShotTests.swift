// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// Opens the Safari page in each of its states from a seeded source, without Safari,
/// and attaches a screenshot of each.
final class SafariSourceShotTests: XCTestCase {
    private static let states: [(mode: String, probe: String, element: String)] = [
        ("setUp", "readyToSetUp", "safari.page.step1"),
        ("addSite", "readyToSetUp", "safari.page.step1.done"),
        ("chooseEverySite", "readyToSetUp", "safari.page.everySite"),
        ("chooseOneAtATime", "readyToSetUp", "safari.page.oneAtATime.otherWebsites"),
        ("on", "active", "safari.page.openSettings"),
        ("waiting", "active", "safari.page.waiting"),
        ("off", "off", "safari.page.openSettings"),
        ("full", "needsAttention", "safari.page.subtext"),
    ]

    @MainActor
    func testWaitingSafariPeriodAppearsInStatusAndOpensSafari() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-reset-on-this-phone", "--ui-test-safari=waiting",
            "--ui-test-open-pane=status"]
        app.launch()
        let row = app.descendants(matching: .any)["shell.pane.status.waiting.safari"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let lead = app.descendants(matching: .any)["shell.pane.status.lead"].firstMatch
        XCTAssertEqual(lead.label.components(separatedBy: ",").first, "1")
        let pill = app.buttons.matching(identifier: "dayHome.statusPill").firstMatch
        let pillCount = pill.label + " " + ((pill.value as? String) ?? "")
        XCTAssertNotNil(pillCount.range(of: "\\b1\\b", options: .regularExpression))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "status-with-waiting-safari"
        shot.lifetime = .keepAlways
        add(shot)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["safari.page.waiting"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testWaitingImportsOpenTheImportPane() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-seed-waiting-import",
            "--ui-test-open-pane=status"]
        app.launch()
        let row = app.descendants(matching: .any)["shell.pane.status.waiting.import"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let lead = app.descendants(matching: .any)["shell.pane.status.lead"].firstMatch
        XCTAssertEqual(lead.label.components(separatedBy: ",").first, "1")
        let pill = app.buttons.matching(identifier: "dayHome.statusPill").firstMatch
        let pillCount = pill.label + " " + ((pill.value as? String) ?? "")
        XCTAssertNotNil(pillCount.range(of: "\\b1\\b", options: .regularExpression))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "status-with-waiting-import"
        shot.lifetime = .keepAlways
        add(shot)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.import"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testFreshLocationOpensEnrollmentWithoutStartingIt() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-no-journal", "--ui-test-open-pane=source:location"]
        app.launch()
        XCTAssertTrue(app.buttons["location.enrollment.turnOn"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "location-first-setup"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    @MainActor
    func testCaptureEachSafariPageState() throws {
        for (index, state) in Self.states.enumerated() {
            let app = XCUIApplication()
            app.launchArguments += [
                "--ui-test",
                "--ui-test-no-journal",
                "--ui-test-safari=\(state.mode)",
                "--ui-test-open-pane=source:safari",
            ]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad opens sources in the split view")
            XCTAssertTrue(
                app.descendants(matching: .any)["safari.page.state.\(state.probe)"].waitForExistence(timeout: 15),
                "Safari page never reached \(state.probe)"
            )
            XCTAssertTrue(
                app.descendants(matching: .any)[state.element].waitForExistence(timeout: 5),
                "\(state.element) missing in \(state.mode)"
            )
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "safari-0\(index + 1)-\(state.mode)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
