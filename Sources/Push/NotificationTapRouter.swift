// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UserNotifications
import os

nonisolated private let log = Logger(subsystem: "app.solstone.swift", category: "router")

final class NotificationTapRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    nonisolated struct TapPayload {
        let categoryIdentifier: String
        let userInfo: [AnyHashable: Any]
    }

    private let onRoute: @MainActor @Sendable (NotificationRoute) -> Void

    init(onRoute: @escaping @MainActor @Sendable (NotificationRoute) -> Void) {
        self.onRoute = onRoute
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let route = Self.route(
            categoryId: content.categoryIdentifier,
            userInfo: content.userInfo
        )
        let onRoute = self.onRoute

        Task { @MainActor [onRoute, route] in
            log.info("routed to \(route.logLabel, privacy: .public)")
            onRoute(route)
        }

        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated static func route(from response: UNNotificationResponse) -> NotificationRoute {
        let content = response.notification.request.content
        return self.route(
            categoryId: content.categoryIdentifier,
            userInfo: content.userInfo
        )
    }

    nonisolated static func route(from payload: TapPayload) -> NotificationRoute {
        self.route(
            categoryId: payload.categoryIdentifier,
            userInfo: payload.userInfo
        )
    }

    nonisolated static func route(categoryId: String, userInfo: [AnyHashable: Any]) -> NotificationRoute {
        let data = userInfo["data"] as? [String: Any]
        if let action = data?["action"] as? String {
            log.info("resolving tap category=\(categoryId, privacy: .public) action=\(action, privacy: .public)")
        } else {
            log.info("resolving tap category=\(categoryId, privacy: .public)")
        }

        return .today
    }

#if DEBUG
    @MainActor
    func debugSynthesizeTap(_: String) {
        let route = NotificationRoute.today
        log.info("routed to \(route.logLabel, privacy: .public)")
        self.onRoute(route)
    }
#endif
}
