// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

final class MockNavHintPoller: NavHintPolling, @unchecked Sendable {
    var hints: [String] = []
    var fetchCallCount = 0
    var lastLocalPort: Int?
    var lastCallId: String?

    func fetch(localPort: Int, callId: String) async -> [String] {
        self.fetchCallCount += 1
        self.lastLocalPort = localPort
        self.lastCallId = callId
        return self.hints
    }
}
