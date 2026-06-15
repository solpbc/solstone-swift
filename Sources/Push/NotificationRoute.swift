// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum NotificationRoute: Sendable, Equatable {
    enum PortalNavTarget: Sendable, Equatable {
        case hash(String)
        case path(String)

        var logLabel: String {
            switch self {
            case .hash(let hash):
                return hash
            case .path(let path):
                return path
            }
        }
    }

    static let solChatPath = "/app/chat/"

    case today
    case solChatRequest

    var portalNavTarget: PortalNavTarget {
        switch self {
        case .today:
            return .hash("today")
        case .solChatRequest:
            return .path(Self.solChatPath)
        }
    }

    var logLabel: String {
        self.portalNavTarget.logLabel
    }
}
