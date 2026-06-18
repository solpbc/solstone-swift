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
    func testDayZeroOverlayShowsProgressCounts() throws {
        let app = try self.makeApp()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)

        XCTAssertTrue(app.staticTexts["5 segments observed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 meetings detected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["8 entities identified"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["browse your journal"].waitForExistence(timeout: 5))
    }

    
    @MainActor
    func testDayOneAcknowledgmentDismissesOnce() throws {
        let app = try self.makeApp()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)

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

    
    @MainActor
    func testOfflineShellShowsNativeDayHome() {
        let app = self.makeSeededApp(extraArguments: [
            "--ui-test-shell-disconnected",
            "--ui-test-network-unsatisfied",
            "--integration-test-push-tap=chat",
        ])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)

        let bannerText = app.staticTexts["offline — safe on this phone · your journal will catch up"]
        let bannerElement = app.otherElements["Offline. Safe on this phone; your journal will catch up."]
        XCTAssertTrue(
            bannerText.waitForExistence(timeout: 10) || bannerElement.waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 5))
        let locality = app.buttons["dayHome.locality"]
        XCTAssertTrue(locality.waitForExistence(timeout: 5))
        XCTAssertEqual(locality.label, "your journal · offline")
        let askBar = app.buttons["dayHome.askBar"]
        XCTAssertTrue(askBar.waitForExistence(timeout: 5))
        XCTAssertTrue(askBar.isEnabled)
        let askHint = app.staticTexts["dayHome.askBar.hint"]
        XCTAssertTrue(askHint.waitForExistence(timeout: 5))
        XCTAssertEqual(askHint.label, "journal offline")
        XCTAssertFalse(app.staticTexts["portal.warmCard"].exists)
        XCTAssertFalse(app.buttons["dayHome.openInJournal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.surface"].waitForExistence(timeout: 3))
        askBar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["your journal isn't reachable right now — i'll send your question the moment it's back."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPairedConnectedDayHomeShowsOpenJournalAndAskChat() {
        let app = self.makeIntegrationApp(extraArguments: ["--integration-test-push-tap=briefing"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["dayHome.openInJournal"].waitForExistence(timeout: 5))
        app.buttons["dayHome.askBar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.surface"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChatComposerAcceptsMessageInIntegrationMode() {
        let app = self.makeIntegrationApp()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        self.assertDayHomeRoot(in: app)

        app.buttons["dayHome.askBar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.surface"].waitForExistence(timeout: 5))

        let textField = app.textFields["ask sol…"]
        if textField.waitForExistence(timeout: 5) {
            textField.tap()
            textField.typeText("what did jack say?")
        } else {
            let textView = app.textViews["ask sol…"]
            XCTAssertTrue(textView.waitForExistence(timeout: 5))
            textView.tap()
            textView.typeText("what did jack say?")
        }

        let chatSurface = app.descendants(matching: .any)["chat.surface"]
        let sendButton = chatSurface.buttons["send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        XCTAssertTrue(app.staticTexts["what did jack say?"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTodayPushRouteLandsOnNativeDayHome() {
        let app = self.makeIntegrationApp(extraArguments: ["--integration-test-push-tap=briefing"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(app.descendants(matching: .any)["dayHome.surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["chat.surface"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testChatPushRoutePresentsChat() {
        let app = self.makeIntegrationApp(extraArguments: ["--integration-test-push-tap=chat"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(app.descendants(matching: .any)["chat.surface"].waitForExistence(timeout: 10))
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
