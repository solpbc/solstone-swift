// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class NotificationTapRouterTests: XCTestCase {
    @MainActor
    func testUnknownCategoryRoutesToToday() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: "SOLSTONE_UNKNOWN",
                userInfo: ["data": ["action": "open_briefing"]]
            )
        )

        XCTAssertEqual(route, .today)
        XCTAssertEqual(route.logLabel, "today")
    }

    @MainActor
    func testSolChatRequestRoutesToChat() {
        let route = NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.solChatRequest.rawValue,
                userInfo: ["data": ["action": "open_chat_request", "request_id": "request-123"]]
            )
        )

        XCTAssertEqual(route, .solChatRequest)
        XCTAssertEqual(route.logLabel, "chat")
    }
}
