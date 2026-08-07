// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

typealias WatchAudioRecorderRetentionTaskSpawner = @Sendable (@escaping @Sendable () async -> Void) -> Task<Void, Never>
typealias WatchAudioRecorderTerminalHandoff = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

nonisolated final class WatchAudioRecorderTerminalRetention: Sendable {
    private static let log = Logger(subsystem: "app.solstone.swift", category: "watch-audio-retention")
    private static let retentionWindow: Duration = .seconds(5)
    private static let retiredPairCapacity = 2

    private final class Pair {
        let identity: UUID
        let recorder: AVAudioRecorder
        let forwarder: WatchAudioRecorderTerminalForwarder

        init(identity: UUID, recorder: AVAudioRecorder, forwarder: WatchAudioRecorderTerminalForwarder) {
            self.identity = identity
            self.recorder = recorder
            self.forwarder = forwarder
        }
    }

    private struct RetiredPair {
        let pair: Pair
        let deadline: ContinuousClock.Instant
        var expiryTask: Task<Void, Never>?
    }

    private struct EnrollmentTransition {
        let retirements: [(retirement: RetiredPair, rebaseAfterStop: Bool)]
        let hadIncumbent: Bool
        let evicted: [RetiredPair]
    }

    private struct StopTransition {
        let retirement: RetiredPair?
        let claimedFromPending: Bool
        let evicted: [RetiredPair]
    }

    private enum PairRelease {
        case none
        case terminalPending
        case retired(RetiredPair)
    }

    private struct State {
        var current: Pair?
        /// Exact-cleanup ownership for a pair whose terminal callback has entered.
        /// Count-bounded to one and deliberately carries NO deadline or expiry task:
        /// it must never expire while its exact cleanup is still queued. The retired
        /// deadline is minted fresh when `stopCurrent` or a successor enroll claims it.
        var terminalPending: Pair?
        var retired: [RetiredPair] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let clock: any WatchAudioRecorderRetentionClock
    private let spawnExpiryTask: WatchAudioRecorderRetentionTaskSpawner
    private let terminalHandoff: WatchAudioRecorderTerminalHandoff
    /// Invoked immediately before a retirement state transaction acquires the lock.
    /// Exists so a test can deterministically interpose real elapsed time in the window
    /// between any pre-read and the transaction, proving the deadline is minted inside it.
    private let beforeRetirementTransition: (@MainActor @Sendable () -> Void)?

    init(
        clock: any WatchAudioRecorderRetentionClock = LiveWatchAudioRecorderRetentionClock(),
        spawnExpiryTask: @escaping WatchAudioRecorderRetentionTaskSpawner = { body in
            Task { await body() }
        },
        terminalHandoff: @escaping WatchAudioRecorderTerminalHandoff = { operation in
            Task { @MainActor in operation() }
        },
        beforeRetirementTransition: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.clock = clock
        self.spawnExpiryTask = spawnExpiryTask
        self.terminalHandoff = terminalHandoff
        self.beforeRetirementTransition = beforeRetirementTransition
    }

    @MainActor
    func enroll(
        recorder: AVAudioRecorder,
        source: WatchCaptureSourceToken,
        sink: (any WatchAudioRecorderEventSink)?
    ) {
        let identity = UUID()
        let forwarder = WatchAudioRecorderTerminalForwarder(
            identity: identity,
            source: source,
            sink: sink,
            releasePair: { [weak self] identity in
                self?.releasePair(identity: identity)
            },
            terminalHandoff: self.terminalHandoff
        )
        recorder.delegate = forwarder
        let clock = self.clock
        self.beforeRetirementTransition?()
        let transition = self.state.withLockUnchecked { state -> EnrollmentTransition in
            // Ordinary retirement deadlines are minted INSIDE the transition that
            // retires the pair, so the window starts at the state change itself and
            // cannot be shortened by lock contention before acquisition.
            let claimDeadline = clock.monotonicNow() + Self.retentionWindow
            let claimedPending = state.terminalPending
            state.terminalPending = nil
            let incumbent = state.current
            state.current = Pair(identity: identity, recorder: recorder, forwarder: forwarder)

            var retirements: [(retirement: RetiredPair, rebaseAfterStop: Bool)] = []
            var evicted: [RetiredPair] = []
            // Pending-claimed cleanup rebases its deadline after stop returns.
            // Ordinary incumbent replacement keeps retirement-anchored semantics.
            for (claimed, fromPending) in [(claimedPending, true), (incumbent, false)] {
                guard let claimed else { continue }
                let retirement = RetiredPair(pair: claimed, deadline: claimDeadline, expiryTask: nil)
                retirements.append((retirement, fromPending))
                evicted.append(contentsOf: Self.appendRetired(retirement, to: &state))
            }
            return EnrollmentTransition(
                retirements: retirements,
                hadIncumbent: incumbent != nil,
                evicted: evicted
            )
        }

        if transition.hadIncumbent {
            Self.log.error("watch audio recorder enrolled over an active recorder")
        }
        self.cancelExpiryTasks(for: transition.evicted)
        for (retirement, rebaseAfterStop) in transition.retirements {
            retirement.pair.recorder.stop()
            self.finishRetirement(retirement, rebaseAfterStop: rebaseAfterStop)
        }
    }

    @MainActor
    func stopCurrent() -> TimeInterval {
        let clock = self.clock
        self.beforeRetirementTransition?()
        let transition = self.state.withLockUnchecked { state -> StopTransition in
            // Minted inside the retirement transaction; a callback-time deadline is
            // never reused, and pending-claimed pairs rebase again after stop returns.
            let claimDeadline = clock.monotonicNow() + Self.retentionWindow
            let claimed: Pair?
            let fromPending: Bool
            if let current = state.current {
                state.current = nil
                claimed = current
                fromPending = false
            } else if let pending = state.terminalPending {
                state.terminalPending = nil
                claimed = pending
                fromPending = true
            } else {
                claimed = nil
                fromPending = false
            }
            guard let claimed else {
                return StopTransition(retirement: nil, claimedFromPending: false, evicted: [])
            }
            // Appended to retired inside the same transaction, so a synchronous
            // delegate callback during stop() can still discover and release it.
            let retirement = RetiredPair(pair: claimed, deadline: claimDeadline, expiryTask: nil)
            return StopTransition(
                retirement: retirement,
                claimedFromPending: fromPending,
                evicted: Self.appendRetired(retirement, to: &state)
            )
        }
        guard let retirement = transition.retirement else { return 0 }

        self.cancelExpiryTasks(for: transition.evicted)
        let duration = retirement.pair.recorder.currentTime
        retirement.pair.recorder.stop()
        self.finishRetirement(retirement, rebaseAfterStop: transition.claimedFromPending)
        return duration
    }

    func releasePair(identity: UUID) -> AnyObject? {
        let release = self.state.withLockUnchecked { state -> PairRelease in
            if let current = state.current, current.identity == identity {
                guard state.terminalPending == nil else { return .none }
                state.current = nil
                // No deadline and no expiry task: exact cleanup owns this pair until
                // stopCurrent or a successor enroll claims it.
                state.terminalPending = current
                return .terminalPending
            }
            if state.terminalPending?.identity == identity {
                return .none
            }
            guard let index = state.retired.firstIndex(where: { $0.pair.identity == identity }) else {
                return .none
            }
            return .retired(state.retired.remove(at: index))
        }

        switch release {
        case .none:
            return nil
        case .terminalPending:
            return nil
        case let .retired(retirement):
            retirement.expiryTask?.cancel()
            return retirement.pair
        }
    }

    @MainActor
    func currentURL() -> URL? {
        let current = self.state.withLockUnchecked { $0.current }
        return current?.recorder.url
    }

    @MainActor
    func currentTime() -> TimeInterval {
        let pair = self.state.withLockUnchecked { state in
            state.current ?? state.terminalPending
        }
        return pair?.recorder.currentTime ?? 0
    }

    @MainActor
    func currentIsRecording() -> Bool {
        let current = self.state.withLockUnchecked { $0.current }
        return current?.recorder.isRecording ?? false
    }

    private func armExpiry(for retirement: RetiredPair) {
        let clock = self.clock
        let deadline = retirement.deadline
        let identity = retirement.pair.identity
        let task = self.spawnExpiryTask { [weak self, clock] in
            await clock.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            _ = self?.expirePair(identity: identity)
        }
        let orphanedTask = self.state.withLockUnchecked { state -> Task<Void, Never>? in
            guard let index = state.retired.firstIndex(where: { $0.pair.identity == identity }) else {
                return task
            }
            state.retired[index].expiryTask = task
            return nil
        }
        orphanedTask?.cancel()
    }

    private func expirePair(identity: UUID) -> AnyObject? {
        let removed = self.state.withLockUnchecked { state -> RetiredPair? in
            // Terminal-pending ownership is count-bounded, never time-expired.
            guard let index = state.retired.firstIndex(where: { $0.pair.identity == identity }) else {
                return nil
            }
            return state.retired.remove(at: index)
        }
        return removed?.pair
    }

    /// Completes a retirement after its concrete stop returned. A synchronous
    /// delegate callback during stop() may already have released the pair, in
    /// which case nothing is armed.
    ///
    /// `rebaseAfterStop` applies to pairs claimed out of terminal-pending
    /// cleanup: their five-second window is measured from the instant stop()
    /// RETURNS, so a slow stop or a second claimed pair cannot eat into it.
    /// Ordinary current/incumbent retirement keeps retirement-anchored semantics.
    private func finishRetirement(_ retirement: RetiredPair, rebaseAfterStop: Bool) {
        guard rebaseAfterStop else {
            let stillRetired = self.state.withLockUnchecked { state in
                state.retired.contains { $0.pair.identity == retirement.pair.identity }
            }
            guard stillRetired else { return }
            self.armExpiry(for: retirement)
            return
        }
        let postStopDeadline = self.clock.monotonicNow() + Self.retentionWindow
        let rebased = self.state.withLockUnchecked { state -> RetiredPair? in
            guard let index = state.retired.firstIndex(
                where: { $0.pair.identity == retirement.pair.identity }
            ) else { return nil }
            let fresh = RetiredPair(
                pair: state.retired[index].pair,
                deadline: postStopDeadline,
                expiryTask: state.retired[index].expiryTask
            )
            state.retired[index] = fresh
            return fresh
        }
        guard let rebased else { return }
        self.armExpiry(for: rebased)
    }

    private func cancelExpiryTasks(for retirements: [RetiredPair]) {
        for retirement in retirements {
            retirement.expiryTask?.cancel()
        }
    }

    private static func appendRetired(_ retirement: RetiredPair, to state: inout State) -> [RetiredPair] {
        state.retired.append(retirement)
        guard state.retired.count > Self.retiredPairCapacity else { return [] }
        return [state.retired.removeFirst()]
    }
}
