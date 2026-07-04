// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class NotificationRouteTests: XCTestCase {
    func testDecidePendingRouteBoundsOfflineChatRequestAndPresentsOnline() {
        XCTAssertEqual(
            NotificationRoute.decidePendingRoute(
                .solChatRequest,
                online: false,
                alreadyAppliedOffline: false
            ),
            .dismissOnly
        )
        XCTAssertEqual(
            NotificationRoute.decidePendingRoute(
                .solChatRequest,
                online: false,
                alreadyAppliedOffline: true
            ),
            .ignore
        )
        XCTAssertEqual(
            NotificationRoute.decidePendingRoute(
                .solChatRequest,
                online: true,
                alreadyAppliedOffline: true
            ),
            .present
        )
        XCTAssertEqual(
            NotificationRoute.decidePendingRoute(
                .today,
                online: false,
                alreadyAppliedOffline: false
            ),
            .clear
        )
    }
}
