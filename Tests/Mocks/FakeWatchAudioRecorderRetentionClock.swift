// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os

final class FakeWatchAudioRecorderRetentionClock: WatchAudioRecorderRetentionClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var monotonicReadCount = 0
        var readCountAtFirstRegistration: Int?
        var now: ContinuousClock.Instant
        var sleepers: [Sleeper] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State(now: .now))

    /// Runs inside `sleep(until:)` BEFORE the sleeper registers, so a test can
    /// interpose at the exact window an absolute deadline must be immune to.
    /// Immutable and init-configured: it is established before any expiry task can
    /// spawn, so there is never a concurrent write to this seam.
    private let onBeforeRegister: (@Sendable (FakeWatchAudioRecorderRetentionClock) -> Void)?

    init(onBeforeRegister: (@Sendable (FakeWatchAudioRecorderRetentionClock) -> Void)? = nil) {
        self.onBeforeRegister = onBeforeRegister
    }

    func monotonicNow() -> ContinuousClock.Instant {
        self.state.withLock { state in
            state.monotonicReadCount += 1
            return state.now
        }
    }

    /// Total `monotonicNow()` reads observed. Used to prove the expiry worker
    /// consumes an ABSOLUTE deadline and performs no clock reads of its own — a
    /// relative form must re-read the clock and is therefore observable here.
    var monotonicReadCount: Int {
        self.state.withLock { $0.monotonicReadCount }
    }

    /// Read count at the moment the first sleeper registered.
    var readCountAtFirstRegistration: Int? {
        self.state.withLock { $0.readCountAtFirstRegistration }
    }

    var pendingSleeperCount: Int {
        self.state.withLock { $0.sleepers.count }
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        self.onBeforeRegister?(self)
        await withCheckedContinuation { continuation in
            // Registration is atomic against the absolute deadline: if the clock is
            // already at or past it, resume immediately instead of waiting again.
            let ready = self.state.withLock { state -> Bool in
                if state.readCountAtFirstRegistration == nil {
                    state.readCountAtFirstRegistration = state.monotonicReadCount
                }
                guard deadline > state.now else { return true }
                state.sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func advance(by duration: Duration) async {
        self.advanceImmediately(by: duration)
        await Task.yield()
    }

    func advanceImmediately(by duration: Duration) {
        let sleepers = self.state.withLock { state -> [Sleeper] in
            state.now += duration
            let ready = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return ready
        }
        for sleeper in sleepers {
            sleeper.continuation.resume()
        }
    }
}

/// Minimal lock-backed integer box for capturing a value from a `@Sendable` closure.
final class LockedIntBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Int?.none)
    func set(_ value: Int) { self.lock.withLock { $0 = value } }
    func get() -> Int? { self.lock.withLock { $0 } }
}
