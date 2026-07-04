// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum PendingRouteAction: Equatable {
    case present
    case dismissOnly
    case ignore
    case clear
}

enum NotificationRoute: Sendable, Equatable {
    case today
    case solChatRequest
    case solChatFold(useID: String)

    var logLabel: String {
        switch self {
        case .today:
            "today"
        case .solChatRequest:
            "chat"
        case .solChatFold:
            "chat-fold"
        }
    }
}

extension NotificationRoute {
    nonisolated static func decidePendingRoute(
        _ route: NotificationRoute,
        online: Bool,
        alreadyAppliedOffline: Bool
    ) -> PendingRouteAction {
        switch route {
        case .today:
            return .clear
        case .solChatRequest, .solChatFold:
            if online {
                return .present
            }
            return alreadyAppliedOffline ? .ignore : .dismissOnly
        }
    }
}
