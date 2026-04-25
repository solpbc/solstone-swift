// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest
import Foundation

final class PostPairStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDayZeroOverlayShowsProgressCounts() throws {
        let app = try self.makeApp()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.openTodayTabIfNeeded(in: app)

        XCTAssertTrue(app.staticTexts["5 segments observed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 meetings detected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["8 entities identified"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["browse your journal"].waitForExistence(timeout: 5))
    }

    func testDayOneAcknowledgmentDismissesOnce() throws {
        let app = try self.makeApp()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.openTodayTabIfNeeded(in: app)

        let title = app.staticTexts["your first briefing"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        let continueButton = app.buttons["continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(title.waitForExistence(timeout: 5))
    }

    func testOfflineShellShowsBannerAndVoiceButton() throws {
        let app = try self.makeApp(extraArguments: ["--ui-test-shell-disconnected", "--ui-test-network-unsatisfied"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.openTodayTabIfNeeded(in: app)

        let bannerText = app.staticTexts["offline — showing cached data"]
        let bannerElement = app.otherElements["Offline. Showing cached data."]
        XCTAssertTrue(
            bannerText.waitForExistence(timeout: 10) || bannerElement.waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["voice"].waitForExistence(timeout: 5))
    }
}

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
        var isAvailable = false

        let task = session.dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                isAvailable = true
            }
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 2)
        return isAvailable
    }

    func openTodayTabIfNeeded(in app: XCUIApplication) {
        let todayTab = app.tabBars.buttons["today"]
        if todayTab.waitForExistence(timeout: 5) {
            todayTab.tap()
        }
    }
}
