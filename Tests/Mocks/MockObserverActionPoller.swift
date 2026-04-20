// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

final class MockObserverActionPoller: ObserverActionPolling, @unchecked Sendable {
    var actions: [ObserverAction] = []
    var fetchCallCount = 0
    var lastLocalPort: Int?
    var lastCallId: String?

    func fetchActions(localPort: Int, callId: String) async -> [ObserverAction] {
        self.fetchCallCount += 1
        self.lastLocalPort = localPort
        self.lastCallId = callId
        return self.actions
    }
}
