// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

protocol ObserverClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

struct SystemObserverClock: ObserverClock {
    func now() -> Date {
        Date()
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
