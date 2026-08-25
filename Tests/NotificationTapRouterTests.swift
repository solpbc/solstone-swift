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
    func testSourcesCategoryRoutesToSources() {
        let route = NotificationTapRouter.route(
            categoryId: NotificationTapRouter.sourcesCategoryIdentifier,
            userInfo: [:]
        )

        XCTAssertEqual(route, .sources)
        XCTAssertEqual(route.logLabel, "sources")
        XCTAssertNotEqual(route.logLabel, "today")
    }

    @MainActor
    func testObserverActivityRearmCategoryRoutesToObserverActivityRearm() {
        let route = NotificationTapRouter.route(
            categoryId: NotificationTapRouter.observerActivityRearmCategoryIdentifier,
            userInfo: [:]
        )

        XCTAssertEqual(route, .observerActivityRearm)
        XCTAssertEqual(route.logLabel, "observerActivityRearm")
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

    @MainActor
    func testDebugSynthesizeTapRoutesSourcesAndBriefing() {
#if DEBUG
        var sourcesRoute: NotificationRoute?
        let sourcesRouter = NotificationTapRouter { route in
            sourcesRoute = route
        }
        sourcesRouter.debugSynthesizeTap("sources")
        XCTAssertEqual(sourcesRoute, .sources)

        var rearmRoute: NotificationRoute?
        let rearmRouter = NotificationTapRouter { route in
            rearmRoute = route
        }
        rearmRouter.debugSynthesizeTap("observer-activity-rearm")
        XCTAssertEqual(rearmRoute, .observerActivityRearm)

        var briefingRoute: NotificationRoute?
        let briefingRouter = NotificationTapRouter { route in
            briefingRoute = route
        }
        briefingRouter.debugSynthesizeTap("briefing")
        XCTAssertEqual(briefingRoute, .today)
#endif
    }
}
