// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated protocol TunnelClock: Sendable {
    func monotonicNow() -> ContinuousClock.Instant
    func sleep(for duration: Duration) async
}

nonisolated struct LiveTunnelClock: TunnelClock {
    private let clock = ContinuousClock()

    func monotonicNow() -> ContinuousClock.Instant {
        self.clock.now
    }

    func sleep(for duration: Duration) async {
        try? await self.clock.sleep(for: duration)
    }
}

enum TunnelScenePhase: String, Sendable, Equatable {
    case active
    case inactive
    case background
}
