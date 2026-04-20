// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

final class MockSidebandNotifier: SidebandNotifying, @unchecked Sendable {
    var notifyCallCount = 0
    var lastCallId: String?
    var lastLocalPort: Int?

    func notify(callId: String, localPort: Int) async {
        self.notifyCallCount += 1
        self.lastCallId = callId
        self.lastLocalPort = localPort
    }
}
