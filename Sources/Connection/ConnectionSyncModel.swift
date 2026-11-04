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
        self.publish(verb: "refreshed")
    }

    /// The app returned to the foreground.
    func noteForeground() {
        self.presenter.noteForeground(now: self.clock.now())
        self.step()
    }

    private func step() {
        guard self.presenter.step(self.sample(), now: self.clock.now()) else { return }
        self.publish(verb: "changed")
    }

    private func runTimers() async {
        while !Task.isCancelled {
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
