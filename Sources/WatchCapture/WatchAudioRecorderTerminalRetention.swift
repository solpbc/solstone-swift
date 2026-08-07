// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

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
        var expiryTask: Task<Void, Never>?
    }

    private struct State {
        var current: Pair?
        var retired: [RetiredPair] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let clock: any ObserverClock

    init(clock: any ObserverClock = SystemObserverClock()) {
        self.clock = clock
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
            }
        )
        recorder.delegate = forwarder
        let incumbent = self.state.withLockUnchecked { state -> Pair? in
            let incumbent = state.current
            state.current = Pair(identity: identity, recorder: recorder, forwarder: forwarder)
            return incumbent
        }
        if let incumbent {
            Self.log.error("watch audio recorder enrolled over an active recorder")
            self.retire(pair: incumbent)
        }
    }

    @MainActor
    func stopCurrent() -> TimeInterval {
        guard let pair = self.takeCurrentForRetirement() else { return 0 }
        let duration = pair.recorder.currentTime
        self.retire(pair: pair)
        pair.recorder.stop()
        return duration
    }

    func releasePair(identity: UUID) -> AnyObject? {
        let removed = self.state.withLockUnchecked { state -> RetiredPair? in
            if state.current?.identity == identity {
                let pair = state.current
                state.current = nil
                return pair.map { RetiredPair(pair: $0, expiryTask: nil) }
            }
            guard let index = state.retired.firstIndex(where: { $0.pair.identity == identity }) else {
                return nil
            }
            return state.retired.remove(at: index)
        }
        removed?.expiryTask?.cancel()
        return removed?.pair
    }

    @MainActor
    func currentURL() -> URL? {
        self.state.withLockUnchecked { $0.current?.recorder.url }
    }

    @MainActor
    func currentTime() -> TimeInterval {
        self.state.withLockUnchecked { $0.current?.recorder.currentTime ?? 0 }
    }

    @MainActor
    func currentIsRecording() -> Bool {
        self.state.withLockUnchecked { $0.current?.recorder.isRecording ?? false }
    }

    @MainActor
    private func takeCurrentForRetirement() -> Pair? {
        self.state.withLockUnchecked { state in
            let pair = state.current
            state.current = nil
            return pair
        }
    }

    @MainActor
    private func retire(pair: Pair) {
        let evicted = self.state.withLockUnchecked { state -> RetiredPair? in
            state.retired.append(RetiredPair(pair: pair, expiryTask: nil))
            guard state.retired.count > Self.retiredPairCapacity else { return nil }
            return state.retired.removeFirst()
        }
        evicted?.expiryTask?.cancel()

        let clock = self.clock
        let identity = pair.identity
        let task = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.retentionWindow)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = self?.releasePair(identity: identity)
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
}
