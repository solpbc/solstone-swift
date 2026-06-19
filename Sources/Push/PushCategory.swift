// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UserNotifications

enum PushCategory: String, CaseIterable, Sendable {
    case solChatRequest = "SOLSTONE_SOL_CHAT_REQUEST"
    case solChatFold = "SOLSTONE_SOL_CHAT_FOLD"

    static func unCategories() -> Set<UNNotificationCategory> {
        Set(Self.allCases.map(\.notificationCategory))
    }

    private var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: self.rawValue,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
    }
}
