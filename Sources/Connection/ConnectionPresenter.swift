// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The timing rules between the raw connection facts and the status an owner sees.
///
/// `ConnectionSyncStatus.derive` says what the transport reports right now. This reducer
/// decides what is *shown*, so the status is quick to change when something real happens
/// and never flickers when nothing has:
///
/// - Connected is earned: the tunnel is up **and** the journal was heard from within the
///   lease. One slow probe inside the lease changes nothing; a silent loss shows when the
///   lease runs out.
/// - A hard drop (the tunnel leaves `.connected`) shows at once; recovery shows on the first
///   fresh evidence, with no confirm timer.
/// - A drop, once shown, stays at least `minimumDropDwell`, so connected never flashes away
///   and back.
/// - Not reaching the journal for `offlineAfter` reads as offline rather than connecting.
///   A new attempt (the network returning, the app returning to the foreground) starts over.
/// - At launch and on return to the foreground the last shown state is held for at most
///   `resumeGrace` while a fresh probe answers, so opening the app does not blink.
/// - Syncing lingers `syncingLinger` after the queue drains, so consecutive items don't strobe.
nonisolated struct ConnectionPresenter: Sendable {
    nonisolated struct Policy: Sendable, Equatable {
        /// One full healthy-but-slow probe cycle (3 s interval + 6 s timeout) plus a second.
        var heardLease: TimeInterval = 10
        var minimumDropDwell: TimeInterval = 1
        var offlineAfter: TimeInterval = 30
        var resumeGrace: TimeInterval = 0.5
        var syncingLinger: TimeInterval = 1.5

        nonisolated init(
            heardLease: TimeInterval = 10,
            minimumDropDwell: TimeInterval = 1,
            offlineAfter: TimeInterval = 30,
            resumeGrace: TimeInterval = 0.5,
            syncingLinger: TimeInterval = 1.5
        ) {
            self.heardLease = heardLease
            self.minimumDropDwell = minimumDropDwell
            self.offlineAfter = offlineAfter
            self.resumeGrace = resumeGrace
            self.syncingLinger = syncingLinger
        }
    }

    let policy: Policy
    private(set) var shown: ConnectionSyncStatus
    /// True for `syncingLinger` after the capture queue drains.
    private(set) var syncingLingers = false

    private var holdUntil: Date?
    private var droppedAt: Date?
    private var notReachingSince: Date?
    private var lastHeardAt: Date?
    private var lastNetworkSatisfied: Bool?
    private var lastCaptureBacklog = 0
    private var drainedAt: Date?

    /// A fresh launch has no last state: it shows connecting until connected is earned, and
    /// holds that through the launch grace so a not-yet-started tunnel never flashes offline.
    nonisolated init(policy: Policy = Policy(), now: Date) {
        self.policy = policy
        self.shown = .connecting
        self.holdUntil = now.addingTimeInterval(policy.resumeGrace)
    }

    /// What the facts support right now, before any holding: the raw derivation, with the
    /// connected family withdrawn once the journal hasn't been heard from within the lease.
    nonisolated static func target(
        _ inputs: ConnectionSyncInputs,
        now: Date,
        policy: Policy
    ) -> ConnectionSyncStatus {
        let raw = ConnectionSyncStatus.derive(inputs)
        guard isJournalReachable(raw) else { return raw }
        if let heard = inputs.lastHeardAt, now.timeIntervalSince(heard) <= policy.heardLease {
            return raw
        }
        return inputs.isNetworkSatisfied == false ? .offline : .unreachable
    }

    /// Folds the current facts in. Returns true when the shown status or the linger changed.
    @discardableResult
    mutating func step(_ inputs: ConnectionSyncInputs, now: Date) -> Bool {
        let before = (self.shown, self.syncingLingers)

        if inputs.isNetworkSatisfied == true, self.lastNetworkSatisfied == false {
            self.restartAttempt(now: now)
        }
        self.lastNetworkSatisfied = inputs.isNetworkSatisfied
        self.lastHeardAt = inputs.lastHeardAt
        self.foldBacklog(inputs.captureBacklog, now: now)

        var target = Self.target(inputs, now: now, policy: self.policy)
        let reachable = isJournalReachable(target)
        if reachable {
            self.notReachingSince = nil
        } else {
            let since = self.notReachingSince ?? now
            self.notReachingSince = since
            if target != .offline, now.timeIntervalSince(since) >= self.policy.offlineAfter {
                target = .offline
            }
        }

        if target != self.shown {
            if reachable {
                if let droppedAt = self.droppedAt,
                   now.timeIntervalSince(droppedAt) < self.policy.minimumDropDwell {
                    // Hold the drop long enough to read; connected returns when it ends.
                } else {
                    self.show(target)
                }
            } else if let hold = self.holdUntil, now < hold {
                // Launch or resume: a fresh probe gets a moment to answer first.
            } else {
                if isJournalReachable(self.shown) {
                    self.droppedAt = now
                }
                self.show(target)
            }
        }
        if let hold = self.holdUntil, now >= hold {
            self.holdUntil = nil
        }

        return before != (self.shown, self.syncingLingers)
    }

    /// The app returned to the foreground: hold what is shown while a fresh probe answers,
    /// and treat what follows as a new attempt rather than a continuation of the old one.
    mutating func noteForeground(now: Date) {
        self.holdUntil = now.addingTimeInterval(self.policy.resumeGrace)
        self.restartAttempt(now: now)
    }

    /// Show exactly what the facts support now, with no holding. For seeded test states.
    mutating func reset(_ inputs: ConnectionSyncInputs, now: Date) {
        self.holdUntil = nil
        self.droppedAt = nil
        self.notReachingSince = nil
        self.lastHeardAt = inputs.lastHeardAt
        self.lastNetworkSatisfied = inputs.isNetworkSatisfied
        self.lastCaptureBacklog = inputs.captureBacklog
        self.drainedAt = nil
        self.syncingLingers = false
        self.shown = Self.target(inputs, now: now, policy: self.policy)
        if !isJournalReachable(self.shown) {
            self.notReachingSince = now
        }
    }

    /// The earliest moment after `now` at which a timer could change what is shown, if any.
    func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        if let hold = self.holdUntil { deadlines.append(hold) }
        if let droppedAt = self.droppedAt, !isJournalReachable(self.shown) {
            deadlines.append(droppedAt.addingTimeInterval(self.policy.minimumDropDwell))
        }
        if let since = self.notReachingSince, self.shown != .offline {
            deadlines.append(since.addingTimeInterval(self.policy.offlineAfter))
        }
        if let heard = self.lastHeardAt, isJournalReachable(self.shown) {
            deadlines.append(heard.addingTimeInterval(self.policy.heardLease))
        }
        if let drained = self.drainedAt {
            deadlines.append(drained.addingTimeInterval(self.policy.syncingLinger))
        }
        return deadlines.filter { $0 > now }.min()
    }

    private mutating func show(_ status: ConnectionSyncStatus) {
        self.shown = status
        if isJournalReachable(status) {
            self.droppedAt = nil
        }
    }

    private mutating func restartAttempt(now: Date) {
        if self.notReachingSince != nil {
            self.notReachingSince = now
        }
    }

    private mutating func foldBacklog(_ backlog: Int, now: Date) {
        if backlog > 0 {
            self.drainedAt = nil
            self.syncingLingers = false
        } else if self.lastCaptureBacklog > 0 {
            self.drainedAt = now
            self.syncingLingers = true
        } else if let drained = self.drainedAt,
                  now.timeIntervalSince(drained) >= self.policy.syncingLinger {
            self.drainedAt = nil
            self.syncingLingers = false
        }
        self.lastCaptureBacklog = backlog
    }
}
