// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest
import Foundation
import os

nonisolated final class PostPairStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testOfflineShellShowsNativeDayHome() {
        let app = self.makeSeededApp(extraArguments: [
            "--ui-test-seed-on-this-phone",
            "--ui-test-shell-disconnected",
            "--ui-test-network-unsatisfied",
        ])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)

        let bannerText = app.staticTexts["offline — safe on this phone · your journal will catch up"]
        let bannerElement = app.otherElements["Offline. Safe on this phone; your journal will catch up."]
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 5))
        XCTAssertFalse(bannerText.exists)
        XCTAssertFalse(bannerElement.exists)
        let status = app.buttons["dayHome.statusPill"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("offline"), status.label)
        self.assertDayHomeGreeting(in: app)
        XCTAssertFalse(app.buttons["dayHome.askBar"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["askPreview.sheet"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.surface"].exists)
        XCTAssertFalse(app.staticTexts["portal.warmCard"].exists)
        XCTAssertFalse(app.buttons["dayHome.openInJournal"].exists)
    }

    @MainActor
    func testOfflineLocalityOpensYourJournalDetails() throws {
        let app = self.makeSeededApp(extraArguments: [
            "--ui-test-seed-on-this-phone",
            "--ui-test-shell-disconnected",
            "--ui-test-network-unsatisfied",
        ])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try XCTSkipIf(self.isPadShapedWindow(app), "the phone shell's presentation; iPad routes this opener to the pane root")
        self.assertDayHomeRoot(in: app)

        let shelf = app.buttons["dayHome.yourSolstoneEntry"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        shelf.tap()

        XCTAssertTrue(app.descendants(matching: .any)["shell.pane.shelf"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["journalLives.sheet"].exists)
    }

    @MainActor
    func testSeededOnThisPhoneStatusBlockNavigatesToDiagnostics() {
        let app = self.makeSeededApp(extraArguments: [
            "--ui-test-seed-on-this-phone",
            "--ui-test-shell-disconnected",
            "--ui-test-network-unsatisfied",
        ])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)
        self.openStandaloneOnThisPhoneBrowse(in: app)

        let surface = app.descendants(matching: .any)["onThisPhone.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))

        let status = app.buttons["onThisPhone.status"]
        self.scrollToElement(status, in: surface)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()

        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.lifecycle"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPairedConnectedDayHomeShowsOpenJournal() {
        let app = self.makeIntegrationApp(extraArguments: ["--integration-test-push-tap=briefing"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["dayHome.openInJournal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dayHome.askBar"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["askPreview.sheet"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.surface"].exists)
    }

    @MainActor
    func testTodayPushRouteLandsOnNativeDayHome() {
        let app = self.makeIntegrationApp(extraArguments: ["--integration-test-push-tap=briefing"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["dayHome.askBar"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["askPreview.sheet"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.surface"].exists)
    }
}


@MainActor
private extension PostPairStateTests {
    func makeApp(extraArguments: [String] = []) throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let journalRoot = environment["UI_TEST_JOURNAL_ROOT"] ?? "http://127.0.0.1:8676"
        let sessionKey = environment["UI_TEST_PAIR_SESSION"] ?? "pair-session-test"
        guard self.isSmokeServerAvailable(journalRoot: journalRoot) else {
            throw XCTSkip("wave5 smoke environment not configured")
        }

        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]

        app.launchArguments.append("--ui-test-journal-root=\(journalRoot)")
        app.launchArguments.append("--ui-test-pair-session=\(sessionKey)")

        if let deviceID = environment["UI_TEST_DEVICE_ID"] {
            app.launchArguments.append("--ui-test-device-id=\(deviceID)")
        } else {
            app.launchArguments.append("--ui-test-device-id=device-123")
        }

        app.launchArguments.append(contentsOf: extraArguments)
        return app
    }

    func makeSeededApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launchArguments.append(contentsOf: extraArguments)
        return app
    }

    func makeIntegrationApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test"]
        app.launchArguments.append(contentsOf: extraArguments)
        return app
    }

    func isSmokeServerAvailable(journalRoot: String) -> Bool {
        guard let url = URL(string: "\(journalRoot)/api/pairing/status") else {
            return false
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        let isAvailable = OSAllocatedUnfairLock<Bool>(initialState: false)

        let task = session.dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            isAvailable.withLock { $0 = true }
            }
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 2)
        return isAvailable.withLock { $0 }
    }

    func assertDayHomeRoot(in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
    }

    func scrollToElement(_ element: XCUIElement, in surface: XCUIElement) {
        if element.waitForExistence(timeout: 2) {
            return
        }
        for _ in 1...6 {
            surface.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return
            }
        }
    }
}
