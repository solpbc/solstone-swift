// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Runs at most one reconciliation pass at a time and never loses a request for another.
///
/// This replaces three interacting fields — an arm-once flag, a `.immediate`/`.delayed` pending
/// slot, and the successor task — that between them could *drop* a request: a pass ending and its
/// successor task starting left a window in which a fresh request was silently discarded, and a
/// self-healing arm could monopolise the single slot and starve the productive requests. Here a
/// request is never dropped.
///
/// Semantics preserved from the machinery it replaces: an immediate follow-up runs on its own
/// task turn (so a caller can observe intermediate state between the pass and its successor); a
/// paced follow-up waits one `pace` on the injected clock; and while a pass is running the first
/// urgency requested wins and later requests coalesce onto it. What changes is only that a request
/// arriving in the drop window is now honoured, and an immediate request supersedes a pending
/// paced wait instead of being discarded.
@MainActor
final class OmiReconciliationScheduler {
    enum Urgency {
        case paced
        case immediate
    }

    private let clock: any ObserverClock
    private let pace: Duration
    private let pass: @MainActor () async -> Void
    private var isRunning = false
    private var owed: Urgency?
    private var sleeper: Task<Void, Never>?

    init(clock: any ObserverClock, pace: Duration, pass: @escaping @MainActor () async -> Void) {
        self.clock = clock
        self.pace = pace
        self.pass = pass
    }

    /// Runs a pass now, or — if one is already running — owes one immediately after it.
    func run() async {
        guard !self.isRunning else {
            if self.owed == nil { self.owed = .immediate }
            return
        }
        self.isRunning = true
        self.owed = nil
        await self.pass()
        self.isRunning = false
        if let owed = self.owed {
            self.owed = nil
            self.schedule(owed)
        }
    }

    /// Records that another pass is owed. During a pass the first urgency wins and later requests
    /// coalesce onto it; while idle it is scheduled at once.
    func request(_ urgency: Urgency) {
        if self.isRunning {
            if self.owed == nil { self.owed = urgency }
        } else {
            self.schedule(urgency)
        }
    }

    private func schedule(_ urgency: Urgency) {
        switch urgency {
        case .immediate:
            // An immediate follow-up supersedes a pending paced wait and runs on its own task
            // turn, retaining the scheduler only until it runs.
            self.sleeper?.cancel()
            self.sleeper = nil
            Task { @MainActor in await self.run() }
        case .paced:
            guard self.sleeper == nil else { return }
            self.armSleeper()
        }
    }

    private func armSleeper() {
        let clock = self.clock
        let pace = self.pace
        self.sleeper = Task { @MainActor [weak self, clock, pace] in
            try? await clock.sleep(for: pace)
            // A superseded or torn-down wait must not run its pass even if its clock fires late.
            guard let self, !Task.isCancelled else { return }
            self.sleeper = nil
            await self.run()
        }
    }

    deinit {
        self.sleeper?.cancel()
    }
}
