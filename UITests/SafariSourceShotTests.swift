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
