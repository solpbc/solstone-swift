// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os

final class FakeTunnelClock: TunnelClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: ContinuousClock.Instant
        var sleepers: [Sleeper] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State(now: .now))

    func monotonicNow() -> ContinuousClock.Instant {
        self.state.withLock { $0.now }
    }

    var pendingSleeperCount: Int {
        self.state.withLock { $0.sleepers.count }
    }

    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            let ready = self.state.withLock { state -> Bool in
                let deadline = state.now + duration
                guard deadline > state.now else { return true }
                state.sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func advance(by duration: Duration) async {
        let sleepers = self.state.withLock { state -> [Sleeper] in
            state.now += duration
            let ready = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return ready
        }
        for sleeper in sleepers {
            sleeper.continuation.resume()
        }
        await Task.yield()
    }
}
