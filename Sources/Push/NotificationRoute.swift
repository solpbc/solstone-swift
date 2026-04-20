// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum NotificationRoute: Sendable, Equatable {
    case today
    case commitment(id: String)
    case preMeeting(eventId: String)
    case agentAlert(customPath: String?)

    var portalHash: String {
        switch self {
        case .today:
            return "today"
        case .commitment(let id):
            return id.isEmpty ? "today" : "today/commitment/\(id)"
        case .preMeeting(let eventId):
            return eventId.isEmpty ? "today" : "today/prep/\(eventId)"
        case .agentAlert(let customPath):
            return Self.sanitize(customPath) ?? "today"
        }
    }
}

private extension NotificationRoute {
    static func sanitize(_ customPath: String?) -> String? {
        guard var path = customPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return nil
        }

        if path.hasPrefix("#") {
            path.removeFirst()
        }

        let lowered = path.lowercased()
        guard !path.isEmpty,
              !lowered.hasPrefix("javascript:"),
              !path.contains("://")
        else {
            return nil
        }

        return path
    }
}
