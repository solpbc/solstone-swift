// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UserNotifications

enum PushCategory: String, CaseIterable, Sendable {
    case dailyBriefing = "SOLSTONE_DAILY_BRIEFING"
    case commitmentNudge = "SOLSTONE_COMMITMENT_NUDGE"
    case preMeetingPrep = "SOLSTONE_PRE_MEETING_PREP"
    case agentAlert = "SOLSTONE_AGENT_ALERT"

    static func unCategories() -> Set<UNNotificationCategory> {
        Set(Self.allCases.map(\.notificationCategory))
    }

    private var notificationCategory: UNNotificationCategory {
        switch self {
        case .commitmentNudge:
            return UNNotificationCategory(
                identifier: self.rawValue,
                actions: PushAction.notificationActions,
                intentIdentifiers: [],
                options: []
            )
        case .dailyBriefing, .preMeetingPrep, .agentAlert:
            return UNNotificationCategory(
                identifier: self.rawValue,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        }
    }
}

enum PushAction: String, CaseIterable, Sendable {
    case markDone = "SOLSTONE_ACTION_MARK_DONE"
    case snooze = "SOLSTONE_ACTION_SNOOZE"

    static var notificationActions: [UNNotificationAction] {
        [
            UNNotificationAction(
                identifier: Self.markDone.rawValue,
                title: "mark done",
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: Self.snooze.rawValue,
                title: "snooze",
                options: []
            ),
        ]
    }
}
