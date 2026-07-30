// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchNotificationAdapterGrepTests: XCTestCase {
    func testNotificationSchedulingProtocolHasNoSoundSurface() throws {
        let body = try self.section(
            from: "protocol WatchNotificationScheduling",
            to: "@MainActor\nprotocol WatchLocationProviding",
            in: "Sources/WatchCapture/WatchCaptureProtocols.swift"
        )

        XCTAssertTrue(body.contains("func add(identifier: String, title: String, body: String, triggerDate: Date?) async throws"))
        XCTAssertFalse(body.contains("sound"))
    }

    func testLiveSchedulerRequestsOnlyAlertAuthorization() throws {
        let body = try self.section(
            from: "func requestAuthorization() async throws -> WatchNotificationAuthorizationStatus",
            to: "func add(identifier: String, title: String, body: String, triggerDate: Date?) async throws",
            in: "Watch/Sources/LiveWatchNotificationScheduler.swift"
        )

        XCTAssertTrue(body.contains("requestAuthorization(options: [.alert])"))
        XCTAssertFalse(body.contains(".sound"))
        XCTAssertFalse(body.contains(".badge"))
    }

    func testLiveSchedulerBuildsContentWithoutSound() throws {
        let body = try self.section(
            from: "func add(identifier: String, title: String, body: String, triggerDate: Date?) async throws",
            to: "func removePending(identifier: String)",
            in: "Watch/Sources/LiveWatchNotificationScheduler.swift"
        )

        XCTAssertTrue(body.contains("let content = UNMutableNotificationContent()"))
        XCTAssertTrue(body.contains("content.title = title"))
        XCTAssertTrue(body.contains("content.body = body"))
        XCTAssertTrue(body.contains("UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)"))
        XCTAssertFalse(body.contains("content.sound"))
        XCTAssertFalse(body.contains(".sound"))
    }

    func testLiveSchedulerRemovesPendingByIdentifier() throws {
        let body = try self.section(
            from: "func removePending(identifier: String)",
            to: "nonisolated func userNotificationCenter",
            in: "Watch/Sources/LiveWatchNotificationScheduler.swift"
        )

        XCTAssertTrue(body.contains("removePendingNotificationRequests(withIdentifiers: [identifier])"))
    }

    func testLiveSchedulerWillPresentUsesPureOptionsWithoutSound() throws {
        let body = try self.section(
            from: "nonisolated func userNotificationCenter(",
            to: "private extension LiveWatchNotificationScheduler",
            in: "Watch/Sources/LiveWatchNotificationScheduler.swift"
        )

        XCTAssertTrue(body.contains("watchNoticePresentationOptions()"))
        XCTAssertFalse(body.contains(".sound"))
    }

    func testWatchAppInstallsNotificationDelegate() throws {
        let body = try self.section(
            from: "let notificationScheduler = LiveWatchNotificationScheduler()",
            to: "let diagnosticsStore: WatchRelayDiagnosticsStore?",
            in: "Watch/Sources/SolstoneWatchApp.swift"
        )

        XCTAssertTrue(body.contains("UNUserNotificationCenter.current().delegate = notificationScheduler"))
    }

    func testComplicationProviderUsesTimelineDerivation() throws {
        let body = try self.section(
            from: "func getTimeline(",
            to: "private extension SolstoneWatchComplicationProvider",
            in: "SolstoneWatchComplication/SolstoneWatchComplication.swift"
        )

        XCTAssertTrue(body.contains("watchComplicationTimelinePoints(snapshot: Self.loadSnapshot(), now: now)"))
        XCTAssertTrue(body.contains("Timeline(entries: entries, policy: .never)"))
        XCTAssertFalse(body.contains("SolstoneWatchComplicationEntry(date: Date(), snapshot: Self.loadSnapshot())"))
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOfFile: self.worktreeRoot().appendingPathComponent(path).path, encoding: .utf8)
    }

    private func section(from start: String, to end: String, in path: String) throws -> String {
        let text = try self.contents(path)
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex)
        else {
            throw GrepFailure(path: path, start: start, end: end)
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct GrepFailure: Error, CustomStringConvertible {
    let path: String
    let start: String
    let end: String

    var description: String {
        "Could not find section \(self.start) ... \(self.end) in \(self.path)"
    }
}
