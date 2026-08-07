// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated protocol WatchAudioRecorderRetentionClock: Sendable {
    func monotonicNow() -> ContinuousClock.Instant
    /// Absolute-deadline sleep. Taking the deadline (not a relative interval)
    /// removes the suspension window between reading `monotonicNow()` and
    /// registering the sleep, which a relative form cannot avoid.
    func sleep(until deadline: ContinuousClock.Instant) async
}

nonisolated struct LiveWatchAudioRecorderRetentionClock: WatchAudioRecorderRetentionClock {
    private let clock = ContinuousClock()

    func monotonicNow() -> ContinuousClock.Instant {
        self.clock.now
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        try? await self.clock.sleep(until: deadline)
    }
}
