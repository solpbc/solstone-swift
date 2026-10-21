// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// Opens the calendar page in each of its five states, from a seeded calendar source with no
/// calendar access and no real calendars, and attaches a screenshot of each.
///
/// Extract after a run:
///   xcrun xcresulttool export attachments --path build/ci-ios-test-attempt-1.xcresult \
///     --output-path /tmp/shots
final class CalendarSourceShotTests: XCTestCase {
    private static let states: [(mode: String, element: String)] = [
        ("beforeOn", "calendar.turnOn"),
        ("confirm", "calendar.confirm"),
        ("on", "calendar.pauseResume"),
        ("needsAttention", "calendar.page.attention"),
        ("waitingForUpdate", "calendar.page.delivery"),
    ]

    @MainActor
    func testCaptureEachCalendarPageState() throws {
        for (index, state) in Self.states.enumerated() {
            let app = XCUIApplication()
            app.launchArguments += [
                "--ui-test",
                "--ui-test-no-journal",
                "--ui-test-calendar=\(state.mode)",
                "--ui-test-open-pane=source:calendar",
            ]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad opens sources in the split view")
            XCTAssertTrue(
                app.descendants(matching: .any)["calendar.page.state.\(state.mode)"].waitForExistence(timeout: 15),
                "calendar page never reached \(state.mode)"
            )
            XCTAssertTrue(
                app.descendants(matching: .any)[state.element].waitForExistence(timeout: 5),
                "\(state.element) missing in \(state.mode)"
            )
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "calendar-0\(index + 1)-\(state.mode)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
