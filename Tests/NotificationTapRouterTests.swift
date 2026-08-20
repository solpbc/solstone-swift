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
    func testRetiredChatTokensRouteToToday() {
        XCTAssertEqual(
            NotificationTapRouter.route(categoryId: "SOLSTONE_SOL_CHAT_REQUEST", userInfo: [:]),
            .today
        )
        XCTAssertEqual(
            NotificationTapRouter.route(categoryId: "SOLSTONE_SOL_CHAT_FOLD", userInfo: [:]),
            .today
        )

#if DEBUG
        for token in ["chat", "chat-fold", "chat-fold:turn-1"] {
            var captured: NotificationRoute?
            let router = NotificationTapRouter { route in
                captured = route
            }
            router.debugSynthesizeTap(token)
            XCTAssertEqual(captured, .today, token)
        }
#endif
    }
}
