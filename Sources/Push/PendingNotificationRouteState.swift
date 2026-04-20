// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Observation

@MainActor
@Observable
final class PendingNotificationRouteState {
    var route: NotificationRoute?
}
