// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit
import os

private let backgroundLog = Logger(subsystem: "app.solstone.swift", category: "background")

@MainActor
protocol BackgroundTaskAsserting {
    // Returns false when no background time is available (UIBackgroundTaskIdentifier.invalid).
    func begin(expirationHandler: @escaping @MainActor () -> Void) -> Bool
    func end()
}

@MainActor
final class UIBackgroundTaskAsserter: BackgroundTaskAsserting {
    private var taskID = UIBackgroundTaskIdentifier.invalid

    func begin(expirationHandler: @escaping @MainActor () -> Void) -> Bool {
        self.taskID = UIApplication.shared.beginBackgroundTask {
            MainActor.assumeIsolated { expirationHandler() }
        }
        return self.taskID != .invalid
    }

    func end() {
        guard self.taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.taskID)
        self.taskID = .invalid
    }
}

@MainActor
func driveUploadDrain(
    mobileSegment: MobileSegmentUploader,
    omi: ObserverUploader,
    watch: ObserverUploader,
    importQueue: ImportQueue,
    watchDrain: WatchSegmentDrain?
) async {
    await mobileSegment.resumeFromDisk()
    await omi.reconcilePortAndResume()
    await watch.reconcilePortAndResume()
    await importQueue.resumeFromDisk()
    await mobileSegment.retryFailed()
    await omi.retryFailed()
    await watch.retryFailed()
    await importQueue.retryFailed()
    await watchDrain?.drain()
}

@MainActor
final class BackgroundDrainCoordinator {
    private let totals: () -> (failed: Int, pending: Int)
    private let inFlight: () -> Int
    private let isSustaining: () -> Bool
    private let isConnected: () -> Bool
    private let drive: () async -> Void
    private let disconnect: () async -> Void
    private let asserter: any BackgroundTaskAsserting
    private let clock: any ObserverClock
    private let settleInterval: Duration

    private var expired = false
    private var ended = false

    init(
        totals: @escaping () -> (failed: Int, pending: Int),
        inFlight: @escaping () -> Int,
        isSustaining: @escaping () -> Bool,
        isConnected: @escaping () -> Bool,
        drive: @escaping () async -> Void,
        disconnect: @escaping () async -> Void,
        asserter: any BackgroundTaskAsserting,
        clock: any ObserverClock = SystemObserverClock(),
        settleInterval: Duration = .seconds(2)
    ) {
        self.totals = totals
        self.inFlight = inFlight
        self.isSustaining = isSustaining
        self.isConnected = isConnected
        self.drive = drive
        self.disconnect = disconnect
        self.asserter = asserter
        self.clock = clock
        self.settleInterval = settleInterval
    }

    func run() async {
        // Outcome 1: sustain-and-survive - location-Always background sustain is live. Keep tunnel + port.
        if self.isSustaining() {
            backgroundLog.info("background: location-always sustain active; keeping tunnel connected")
            return
        }

        let initial = self.totals()
        let backlog = initial.failed + initial.pending

        // Outcome 3: disconnect-now - nothing to drain (or not connected, so driving cannot help).
        guard self.isConnected(), backlog > 0 else {
            await self.disconnect()
            return
        }

        // Outcome 2: drain-then-disconnect under a background-task assertion.
        guard self.asserter.begin(expirationHandler: { [weak self] in self?.handleExpiration() }) else {
            // No background time granted - do not start a drain we cannot hold.
            backgroundLog.info("background: no background time; disconnecting")
            await self.disconnect()
            return
        }
        defer { self.endAssertion() }

        var previous = backlog
        var stalledRounds = 0
        while !self.expired && !Task.isCancelled {
            await self.drive()
            if self.expired || Task.isCancelled { break }
            let current = self.totals()
            let total = current.failed + current.pending
            if total == 0 { break }
            let n = self.inFlight()
            if total < previous {
                previous = total
                stalledRounds = 0
            } else if n > 0 {
                stalledRounds = 0
            } else {
                stalledRounds += 1
                if stalledRounds >= 2 { break }
            }
            do { try await self.clock.sleep(for: self.settleInterval) } catch { break }
        }

        self.endAssertion()
        // Foreground takeover cancelled us - leave the tunnel as-is for the .active branch to manage.
        if Task.isCancelled { return }
        let exitInFlight = self.inFlight()
        if self.expired {
            backgroundLog.info("background: stopped at expiration with \(exitInFlight, privacy: .public) in-flight")
        } else {
            let remaining = self.totals()
            let remainingTotal = remaining.failed + remaining.pending
            backgroundLog.info("background: clean quiesce (remaining \(remainingTotal, privacy: .public), in-flight \(exitInFlight, privacy: .public))")
        }
        await self.disconnect()
    }

    private func handleExpiration() {
        self.expired = true
        self.endAssertion()
    }

    private func endAssertion() {
        guard !self.ended else { return }
        self.ended = true
        self.asserter.end()
    }
}
