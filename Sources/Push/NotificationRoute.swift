// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum NotificationRoute: Sendable, Equatable {
    case today

    var logLabel: String {
        "today"
    }
}
