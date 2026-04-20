// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "router")

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
            // TODO(wave-3-followup): dispatch SOLSTONE_ACTION_MARK_DONE / SOLSTONE_ACTION_SNOOZE
            // to /api/commitments/{id}/complete|snooze once the server endpoints land.
            log.info("routed to \(route.portalHash, privacy: .public)")
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

        switch categoryId {
        case PushCategory.dailyBriefing.rawValue:
            return .today
        case PushCategory.commitmentNudge.rawValue:
            guard let id = data?["commitment_id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .today
            }
            return .commitment(id: id)
        case PushCategory.preMeetingPrep.rawValue:
            guard let eventId = data?["event_id"] as? String,
                  !eventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .today
            }
            return .preMeeting(eventId: eventId)
        case PushCategory.agentAlert.rawValue:
            return .agentAlert(customPath: data?["custom_path"] as? String)
        default:
            return .today
        }
    }

#if DEBUG
    @MainActor
    func debugSynthesizeTap(_ kind: String) {
        let route = switch kind {
        case "commitment":
            NotificationRoute.commitment(id: "debug-commitment")
        case "prep":
            NotificationRoute.preMeeting(eventId: "debug-event")
        case "alert":
            NotificationRoute.agentAlert(customPath: "#today/alert")
        default:
            NotificationRoute.today
        }

        log.info("routed to \(route.portalHash, privacy: .public)")
        self.onRoute(route)
    }
#endif
}
