// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import BackgroundTasks
import Foundation
import Observation
import os

private let exportBgLog = Logger(subsystem: "app.solstone.swift", category: "export-background")

/// Snapshot of an active journal export download tracked by `BGContinuedProcessingTask`.
nonisolated struct ExportBackgroundDownloadTarget: Equatable, Sendable {
    let exportID: String
    let filename: String
    let bytesWritten: Int64
    let bytesTotal: Int64
    let phase: String
}

/// Manages a dedicated `BGContinuedProcessingTask` for native journal export downloads on
/// iPhone and iPad. Keeps the SPL tunnel alive across brief background transitions, updates
/// `task.progress` on confirmed written bytes, and pauses cleanly on OS expiration without
/// removing the resumable `.part` file in the owner's chosen folder.
@MainActor
@Observable
final class ExportBackgroundDownloadCoordinator {
    static let taskIdentifierPrefix = "app.solstone.swift.export-download"
    static let defaultReconnectGraceTimeout: TimeInterval = 30

    enum Outcome: Equatable {
        case completed
        case paused
        case stopped
    }

    private(set) var isRunning = false
    /// `true` strictly while iOS is executing `runTask` so `BackgroundDrainCoordinator`
    /// preserves the live tunnel only when the OS actually grants continued processing.
    private(set) var isSustainingBackground = false
    private(set) var lastOutcome: Outcome?

    @ObservationIgnored private let activeTarget: () -> ExportBackgroundDownloadTarget?
    @ObservationIgnored private let isConnected: () -> Bool
    @ObservationIgnored private let onExpirePause: () -> Void
    @ObservationIgnored private let shouldDisconnectOnExit: () -> Bool
    @ObservationIgnored private let disconnect: () async -> Void
    @ObservationIgnored private let scheduling: any FinishSyncingScheduling
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let settleInterval: Duration
    @ObservationIgnored private let reconnectGraceTimeout: TimeInterval

    @ObservationIgnored private var expired = false
    @ObservationIgnored private var activeTaskHandle: (any FinishSyncingTaskHandle)?
    @ObservationIgnored private var lastObservedTarget: ExportBackgroundDownloadTarget?
    @ObservationIgnored private var lastProgressTotalUnits = 1

    init(
        activeTarget: @escaping () -> ExportBackgroundDownloadTarget?,
        isConnected: @escaping () -> Bool,
        onExpirePause: @escaping () -> Void,
        shouldDisconnectOnExit: @escaping () -> Bool = { false },
        disconnect: @escaping () async -> Void = {},
        scheduling: any FinishSyncingScheduling = BGTaskSchedulerAdapter(),
        clock: any ObserverClock = SystemObserverClock(),
        settleInterval: Duration = .seconds(1),
        reconnectGraceTimeout: TimeInterval = ExportBackgroundDownloadCoordinator.defaultReconnectGraceTimeout
    ) {
        self.activeTarget = activeTarget
        self.isConnected = isConnected
        self.onExpirePause = onExpirePause
        self.shouldDisconnectOnExit = shouldDisconnectOnExit
        self.disconnect = disconnect
        self.scheduling = scheduling
        self.clock = clock
        self.settleInterval = settleInterval
        self.reconnectGraceTimeout = max(0, reconnectGraceTimeout)
    }

    nonisolated static func progressUnits(bytesWritten: Int64, bytesTotal: Int64) -> (completed: Int, total: Int) {
        let safeTotal = max(Int64(1), bytesTotal)
        let safeWritten = min(max(Int64(0), bytesWritten), safeTotal)
        if safeTotal <= 1024 {
            return (Int(safeWritten), Int(safeTotal))
        }
        let totalKiB = max(1, Int((safeTotal + 1023) / 1024))
        let writtenKiB = min(totalKiB, Int(safeWritten / 1024))
        let clamped = (safeWritten < safeTotal && writtenKiB >= totalKiB) ? max(0, totalKiB - 1) : writtenKiB
        return (clamped, totalKiB)
    }

    func submitIfNeeded(target: ExportBackgroundDownloadTarget) {
        self.lastObservedTarget = target
        guard !self.isRunning else {
            if let handle = self.activeTaskHandle {
                self.applyProgress(to: handle, target: target)
            }
            return
        }
        self.lastOutcome = nil
        let identifier = Self.taskIdentifierPrefix + "." + UUID().uuidString
        let didRegister = self.scheduling.register(identifier: identifier) { [weak self] handle in
            guard let self else { return }
            Task { @MainActor in
                await self.runTask(handle)
            }
        }
        guard didRegister else {
            exportBgLog.notice("export-background: dynamic registration unavailable for \(identifier, privacy: .public)")
            return
        }
        do {
            try self.scheduling.submit(
                identifier: identifier,
                title: AppStrings.ios_app_exportbgsystemtitle(),
                subtitle: target.filename
            )
            self.isRunning = true
            exportBgLog.info("export-background: submitted id=\(identifier, privacy: .public)")
        } catch {
            exportBgLog.notice("export-background: submit declined: \(String(describing: error), privacy: .public)")
        }
    }

    func handleProgress(_ target: ExportBackgroundDownloadTarget) {
        self.lastObservedTarget = target
        guard let handle = self.activeTaskHandle else { return }
        self.applyProgress(to: handle, target: target)
    }

    func runTask(_ handle: any FinishSyncingTaskHandle) async {
        exportBgLog.info("export-background: runTask started")
        self.expired = false
        handle.setExpirationHandler { [weak self] in
            self?.expired = true
            self?.onExpirePause()
        }
        self.isRunning = true
        self.isSustainingBackground = true
        self.activeTaskHandle = handle
        defer {
            self.activeTaskHandle = nil
            self.isSustainingBackground = false
            self.isRunning = false
        }

        if let target = self.activeTarget() ?? self.lastObservedTarget {
            self.lastObservedTarget = target
            self.applyProgress(to: handle, target: target)
        } else {
            self.lastProgressTotalUnits = 1
            handle.setProgressTotal(1)
            handle.setProgressCompleted(0)
            handle.updateTitle(AppStrings.ios_app_exportbgsystemtitle(), subtitle: "")
        }

        var disconnectedSince: Date?
        while !self.expired && !handle.isCancelled {
            guard let current = self.activeTarget() else { break }
            self.lastObservedTarget = current
            self.applyProgress(to: handle, target: current)
            if current.phase != "transferring" && current.phase != "verifying" {
                break
            }
            if !self.isConnected() {
                let now = self.clock.now()
                if disconnectedSince == nil { disconnectedSince = now }
                if let since = disconnectedSince, now.timeIntervalSince(since) >= self.reconnectGraceTimeout {
                    break
                }
            } else {
                disconnectedSince = nil
            }
            do {
                try await self.clock.sleep(for: self.settleInterval)
            } catch {
                break
            }
        }

        let finalTarget = self.activeTarget() ?? self.lastObservedTarget
        let completedCleanly = !self.expired && !handle.isCancelled && finalTarget?.phase == "saved"
        let resumablePause = !completedCleanly && (self.expired || finalTarget?.phase == "paused" || finalTarget?.phase == "transferring" || finalTarget?.phase == "verifying")
        if completedCleanly {
            handle.setProgressTotal(self.lastProgressTotalUnits)
            handle.setProgressCompleted(self.lastProgressTotalUnits)
            handle.updateTitle(AppStrings.ios_app_exportbgsystemdonetitle(), subtitle: finalTarget?.filename ?? "")
            self.lastOutcome = .completed
        } else if resumablePause {
            if self.expired || handle.isCancelled {
                self.onExpirePause()
            }
            handle.updateTitle(AppStrings.ios_app_exportbgsystempausedtitle(), subtitle: finalTarget?.filename ?? "")
            self.lastOutcome = .paused
        } else {
            handle.updateTitle(AppStrings.ios_app_exportbgsystemstoppedtitle(), subtitle: finalTarget?.filename ?? "")
            self.lastOutcome = .stopped
        }

        handle.complete(success: completedCleanly)
        self.activeTaskHandle = nil
        self.isSustainingBackground = false
        if self.shouldDisconnectOnExit() {
            await self.disconnect()
        }
        self.isRunning = false
    }

    private func applyProgress(to handle: any FinishSyncingTaskHandle, target: ExportBackgroundDownloadTarget) {
        guard target.phase == "transferring" || target.phase == "verifying" else { return }
        let units = Self.progressUnits(bytesWritten: target.bytesWritten, bytesTotal: target.bytesTotal)
        self.lastProgressTotalUnits = units.total
        handle.setProgressTotal(units.total)
        handle.setProgressCompleted(units.completed)
        let title = target.phase == "verifying"
            ? AppStrings.ios_app_exportbgsystemchecking()
            : AppStrings.ios_app_exportbgsystemtitle()
        handle.updateTitle(title, subtitle: target.filename)
    }
}
