// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum ObserverAction: Equatable, Sendable {
    case startObserver(mode: ObserverMode)
}

nonisolated protocol ObserverActionPolling: Sendable {
    func fetchActions(localPort: Int, callId: String) async -> [ObserverAction]
}
