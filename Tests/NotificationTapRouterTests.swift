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

    @MainActor
    func testSolChatFoldRoutesWithValidUseID() {
        let route = self.chatFoldRoute(data: ["action": "open_chat_fold", "use_id": "turn-1"])

        XCTAssertEqual(route, .solChatFold(useID: "turn-1"))
        XCTAssertEqual(route.logLabel, "chat-fold")
    }

    @MainActor
    func testSolChatFoldTrimsUseID() {
        let route = self.chatFoldRoute(data: ["action": "open_chat_fold", "use_id": "  turn-1\n"])

        XCTAssertEqual(route, .solChatFold(useID: "turn-1"))
    }

    @MainActor
    func testSolChatFoldMissingUseIDFallsBackToChat() {
        let route = self.chatFoldRoute(data: ["action": "open_chat_fold"])

        XCTAssertEqual(route, .solChatRequest)
    }

    @MainActor
    func testSolChatFoldEmptyUseIDFallsBackToChat() {
        let empty = self.chatFoldRoute(data: ["action": "open_chat_fold", "use_id": ""])
        let whitespace = self.chatFoldRoute(data: ["action": "open_chat_fold", "use_id": " \n "])

        XCTAssertEqual(empty, .solChatRequest)
        XCTAssertEqual(whitespace, .solChatRequest)
    }

    @MainActor
    func testSolChatFoldWrongTypeUseIDFallsBackToChat() {
        let route = self.chatFoldRoute(data: ["action": "open_chat_fold", "use_id": 42])

        XCTAssertEqual(route, .solChatRequest)
    }

    @MainActor
    func testSolChatFoldNestedOriginOnlyFallsBackToChat() {
        let route = self.chatFoldRoute(data: [
            "action": "open_chat_fold",
            "origin": ["logical_use_id": "turn-1"]
        ])

        XCTAssertEqual(route, .solChatRequest)
    }

    @MainActor
    func testSolChatFoldIgnoresContentFields() {
        let route = self.chatFoldRoute(data: [
            "action": "open_chat_fold",
            "use_id": "turn-1",
            "ask": "private question",
            "answer": "private answer",
            "text": "private text"
        ])

        XCTAssertEqual(route, .solChatFold(useID: "turn-1"))
    }

    private func chatFoldRoute(data: [String: Any]) -> NotificationRoute {
        NotificationTapRouter.route(
            from: .init(
                categoryIdentifier: PushCategory.solChatFold.rawValue,
                userInfo: ["data": data]
            )
        )
    }
}
