// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let connectionSyncLog = Logger(subsystem: "app.solstone.swift", category: "connection-sync")

/// Runs `ConnectionPresenter` against the live inputs: on every observed input change, and
/// on a timer that wakes when one of the presenter's holds or leases comes due.
@MainActor
@Observable
final class ConnectionSyncModel {
    private(set) var status: ConnectionSyncStatus
    /// The capture queue drained moments ago; the pill keeps reading syncing until this clears.
    private(set) var syncingLingers: Bool = false

    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let pollCadence: Duration
    @ObservationIgnored private let sample: @MainActor () -> ConnectionSyncInputs
    @ObservationIgnored private var presenter: ConnectionPresenter
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var foregroundWaiter: CheckedContinuation<Void, Never>?

    init(
        clock: any ObserverClock,
        policy: ConnectionPresenter.Policy = ConnectionPresenter.Policy(),
        pollCadence: Duration = .seconds(1),
        sample: @escaping @MainActor () -> ConnectionSyncInputs
    ) {
        self.clock = clock
        self.pollCadence = pollCadence
        self.sample = sample
        var presenter = ConnectionPresenter(policy: policy, now: clock.now())
        presenter.step(sample(), now: clock.now())
        self.presenter = presenter
        self.status = presenter.shown
        self.syncingLingers = presenter.syncingLingers
    }

    func run() async {
        guard !self.isRunning else { return }
        self.isRunning = true
        defer { self.isRunning = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.runTimers()
            }
            group.addTask { [weak self] in
                await self?.observeInputChanges()
            }
            await group.waitForAll()
        }
    }

    /// Show exactly what the current facts support, skipping every hold. For seeded states.
    func refreshNow() {
        self.presenter.reset(self.sample(), now: self.clock.now())
        self.noteStepped()
        self.publish(verb: "refreshed")
    }

    /// The app returned to the foreground.
    func noteForeground() {
        self.presenter.noteForeground(now: self.clock.now())
        self.publish(verb: "foreground")
        self.step()
    }

    /// Whether the journal reads as reachable now, for anything that acts on it. False while the
    /// status may be out of date, until the first step back in the foreground.
    var isJournalReachableNow: Bool {
        self.statusIsCurrent && isJournalReachable(self.status)
    }

    /// False from the moment the timer parks in the background until the first step back in
    /// the foreground: a status that changes with time alone, such as the journal going quiet,
    /// is not re-derived while parked.
    private(set) var statusIsCurrent = true

    /// Nothing shows the status while the app is in the background, so the timer stops there;
    /// input changes are still taken as they come. Leaving the background starts it again.
    func setInBackground(_ inBackground: Bool) {
        self.inBackground = inBackground
        if inBackground {
            if self.statusIsCurrent { self.statusIsCurrent = false }
        } else {
            self.resumeTimer()
        }
    }

    private func noteStepped() {
        if !self.inBackground, !self.statusIsCurrent { self.statusIsCurrent = true }
    }

    private func resumeTimer() {
        let waiter = self.foregroundWaiter
        self.foregroundWaiter = nil
        waiter?.resume()
    }

    private func waitForForeground() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.inBackground, !Task.isCancelled {
                    self.foregroundWaiter = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeTimer() }
        }
    }

    private func step() {
        let changed = self.presenter.step(self.sample(), now: self.clock.now())
        self.noteStepped()
        guard changed else { return }
        self.publish(verb: "changed")
    }

    private func runTimers() async {
        while !Task.isCancelled {
            if self.inBackground {
                await self.waitForForeground()
                continue
            }
            var wait = self.pollCadence
            let now = self.clock.now()
            if let deadline = self.presenter.nextDeadline(after: now) {
                let untilDeadline = deadline.timeIntervalSince(now)
                wait = min(wait, .milliseconds(max(Int((untilDeadline * 1_000).rounded(.up)), 1)))
            }
            try? await self.clock.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self.step()
        }
    }

    private func observeInputChanges() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.installInputTracking(yielding: continuation)

        for await _ in stream {
            self.installInputTracking(yielding: continuation)
            self.step()
        }
    }

    private func installInputTracking(yielding continuation: AsyncStream<Void>.Continuation) {
        withObservationTracking {
            _ = self.sample()
        } onChange: {
            continuation.yield()
        }
    }

    private func publish(verb: String) {
        let previous = self.status
        let next = self.presenter.shown
        if self.syncingLingers != self.presenter.syncingLingers {
            self.syncingLingers = self.presenter.syncingLingers
        }
        guard next != previous else { return }
        self.status = next
        connectionSyncLog.debug("connection sync status \(verb, privacy: .public) \(previous.statusLine, privacy: .public) -> \(next.statusLine, privacy: .public)")
    }

#if DEBUG && targetEnvironment(simulator)
    func integrationGateCurrentInputs() -> ConnectionSyncInputs {
        self.sample()
    }
#endif
}
