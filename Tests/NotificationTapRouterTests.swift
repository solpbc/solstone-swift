// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class NotificationTapRouterTests: XCTestCase {
    @MainActor
    func testDailyBriefingRoutesToToday() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.dailyBriefing.rawValue,
                userInfo: ["data": ["action": "open_briefing", "date": "2026-04-19"]]
            )
        )

        XCTAssertEqual(route, .today)
        XCTAssertEqual(route.portalHash, "today")
    }

    @MainActor
    func testCommitmentRoutesToCommitmentHash() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.commitmentNudge.rawValue,
                userInfo: ["data": ["commitment_id": "commitment-123"]]
            )
        )

        XCTAssertEqual(route, .commitment(id: "commitment-123"))
        XCTAssertEqual(route.portalHash, "today/commitment/commitment-123")
    }

    @MainActor
    func testPreMeetingRoutesToPrepHash() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.preMeetingPrep.rawValue,
                userInfo: ["data": ["event_id": "event-123"]]
            )
        )

        XCTAssertEqual(route, .preMeeting(eventId: "event-123"))
        XCTAssertEqual(route.portalHash, "today/prep/event-123")
    }

    @MainActor
    func testAgentAlertRejectsJavascriptCustomPath() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.agentAlert.rawValue,
                userInfo: ["data": ["custom_path": "javascript:alert(1)"]]
            )
        )

        XCTAssertEqual(route, .agentAlert(customPath: "javascript:alert(1)"))
        XCTAssertEqual(route.portalHash, "today")
    }

    @MainActor
    func testAgentAlertStripsLeadingHash() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.agentAlert.rawValue,
                userInfo: ["data": ["custom_path": "#today/whatever"]]
            )
        )

        XCTAssertEqual(route, .agentAlert(customPath: "#today/whatever"))
        XCTAssertEqual(route.portalHash, "today/whatever")
    }

    @MainActor
    func testMissingCommitmentIdFallsBackToToday() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.commitmentNudge.rawValue,
                userInfo: ["data": [:]]
            )
        )

        XCTAssertEqual(route, .today)
        XCTAssertEqual(route.portalHash, "today")
    }
}
