// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
protocol ConnectionStallClock: AnyObject {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

@MainActor
final class SystemConnectionStallClock: ConnectionStallClock {
    init() {}

    var now: Date {
        Date()
    }

    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
