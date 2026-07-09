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
    transferEngine: TransferEngine,
    shareImportStore: ShareImportStore,
    shareTransferHolder: ShareTransferHolder,
    diagnosticLog: DiagnosticLog?,
    watchDrain: WatchSegmentDrain?
) async {
    await mobileSegment.resumeFromDisk()
    await transferEngine.kick()
    await resumeShareImports(
        shareImportStore: shareImportStore,
        transferEngine: transferEngine,
        diagnosticLog: diagnosticLog
    )
    if shareTransferHolder.pendingCount > 0 || shareTransferHolder.failedCount > 0 {
        await transferEngine.kick()
    }
    await watchDrain?.drain()
}

@MainActor
func resumeShareImports(
    shareImportStore: ShareImportStore,
    transferEngine: TransferEngine,
    diagnosticLog: DiagnosticLog?
) async {
    shareImportStore.refreshFromDisk()
    guard let appGroupRoot = try? AppGroupContainer.rootURL() else {
        diagnosticLog?.append(
            category: .upload,
            severity: .warning,
            message: "needs attention",
            detail: "source=share reason=app-group unavailable"
        )
        return
    }
    let unresolved = await shareImportStore.adoptToTransfer(
        engine: transferEngine,
        diagnosticLog: diagnosticLog,
        quarantineRootURL: ShareImportTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot)
    )
    if unresolved == 0 {
        await transferEngine.kick()
    }
}

@MainActor
final class BackgroundDrainCoordinator {
    private let totals: () -> (failed: Int, pending: Int)
    private let inFlight: () -> Int
    private let backoff: () -> TransferBackoffStatus
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
        backoff: @escaping () -> TransferBackoffStatus,
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
        self.backoff = backoff
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
        drainLoop: while !self.expired && !Task.isCancelled {
            await self.drive()
            if self.expired || Task.isCancelled { break drainLoop }
            let current = self.totals()
            let total = current.failed + current.pending
            let backoff = self.backoff()
            switch evaluateDrainRound(DrainRoundInput(
                previousTotal: previous,
                currentTotal: total,
                inFlight: self.inFlight(),
                stalledRounds: stalledRounds,
                backoffPendingCount: backoff.backoffPendingCount,
                endpointHeld: backoff.endpointHeld
            )) {
            case .finished, .stalled:
                break drainLoop
            case .keepGoing(let nextPrevious, let nextStalledRounds):
                previous = nextPrevious
                stalledRounds = nextStalledRounds
                do { try await self.clock.sleep(for: self.settleInterval) } catch { break drainLoop }
            }
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
