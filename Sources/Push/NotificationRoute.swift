// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum NotificationRoute: Sendable, Equatable {
    case today
    case solChatRequest

    var logLabel: String {
        switch self {
        case .today:
            "today"
        case .solChatRequest:
            "chat"
        }
    }
}
