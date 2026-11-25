// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import BackgroundTasks
import Foundation
import Observation
import os

private let importBgLog = Logger(subsystem: "app.solstone.swift", category: "import-background")

/// Snapshot of the primary large import tracked by a background continued-processing run.
nonisolated struct ImportBackgroundUploadTarget: Equatable, Sendable {
    let itemID: UUID
    let filename: String
    let bytesSent: Int64
    let bytesTotal: Int64
    let phase: TransferResumablePhase
}

/// Manages a dedicated `BGContinuedProcessingTask` for large file imports on iPhone and iPad.
///
/// Offered directly on `ImportView` for any single large import (without the 25-item backlog
/// threshold used for segment catch-up). Updates `task.progress` on every confirmed chunk so the
/// OS scheduler sees continuous forward progress, survives brief reconnects during Wi-Fi/cellular
/// switches or relay restarts, and pauses cleanly on expiry without deleting local custody bytes
/// or the remote partial upload session.
@MainActor
@Observable
final class ImportBackgroundUploadCoordinator {
    static let taskIdentifierPrefix = "app.solstone.swift.import-upload"
    static let defaultReconnectGraceTimeout: TimeInterval = 30

    enum Outcome: Equatable {
        case completed
        case paused
    }

    enum CardState: Equatable {
        case hidden
        case idle
        case inProgress
        case completed
        case paused
    }

    private struct AppliedSystemState: Equatable {
        let completedUnits: Int
        let totalUnits: Int
        let title: String
        let subtitle: String
    }

    private(set) var availability: FinishSyncingCoordinator.Availability = .ready
    private(set) var isCapable: Bool = true
    private(set) var isRunning = false
    /// `true` strictly while iOS is executing `runTask`. A `.queue` submission that has not
    /// launched (or was cancelled before launch) never sets this, so `BackgroundDrainCoordinator`
    /// keeps its normal drain-and-disconnect behavior until the task actually starts.
    private(set) var isSustainingBackground = false
    private(set) var lastOutcome: Outcome?

    @ObservationIgnored private let activeTarget: () -> ImportBackgroundUploadTarget?
    @ObservationIgnored private let filenameForItem: (UUID) -> String?
    @ObservationIgnored private let pendingSendableCount: () -> Int
    @ObservationIgnored private let inFlightCount: () -> Int
    @ObservationIgnored private let isPairingRefused: () -> Bool
    @ObservationIgnored private let backoff: () -> TransferBackoffStatus
    @ObservationIgnored private let drive: () async -> Void
    @ObservationIgnored private let setPacingMode: (TransferPacingMode) async -> Void
    @ObservationIgnored private let isConnected: () -> Bool
    @ObservationIgnored private let shouldDisconnectOnExit: () -> Bool
    @ObservationIgnored private let disconnect: () async -> Void
    @ObservationIgnored private let scheduling: any FinishSyncingScheduling
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let settleInterval: Duration
    @ObservationIgnored private let reconnectGraceTimeout: TimeInterval

    @ObservationIgnored private var expired = false
    @ObservationIgnored private var activeTaskHandle: (any FinishSyncingTaskHandle)?
    @ObservationIgnored private var lastObservedTarget: ImportBackgroundUploadTarget?
    @ObservationIgnored private var lastAppliedSystemState: AppliedSystemState?
    @ObservationIgnored private var lastProgressTotalUnits = 1

    init(
        activeTarget: @escaping () -> ImportBackgroundUploadTarget?,
        filenameForItem: @escaping (UUID) -> String?,
        pendingSendableCount: @escaping () -> Int,
        inFlightCount: @escaping () -> Int,
        isPairingRefused: @escaping () -> Bool,
        backoff: @escaping () -> TransferBackoffStatus,
        drive: @escaping () async -> Void,
        setPacingMode: @escaping (TransferPacingMode) async -> Void,
        isConnected: @escaping () -> Bool,
        shouldDisconnectOnExit: @escaping () -> Bool = { true },
        disconnect: @escaping () async -> Void,
        scheduling: any FinishSyncingScheduling = BGTaskSchedulerAdapter(),
        clock: any ObserverClock = SystemObserverClock(),
        settleInterval: Duration = .seconds(2),
        reconnectGraceTimeout: TimeInterval = ImportBackgroundUploadCoordinator.defaultReconnectGraceTimeout
    ) {
        self.activeTarget = activeTarget
        self.filenameForItem = filenameForItem
        self.pendingSendableCount = pendingSendableCount
        self.inFlightCount = inFlightCount
        self.isPairingRefused = isPairingRefused
        self.backoff = backoff
        self.drive = drive
        self.setPacingMode = setPacingMode
        self.isConnected = isConnected
        self.shouldDisconnectOnExit = shouldDisconnectOnExit
        self.disconnect = disconnect
        self.scheduling = scheduling
        self.clock = clock
        self.settleInterval = settleInterval
        self.reconnectGraceTimeout = max(0, reconnectGraceTimeout)
    }

    nonisolated static func cardState(
        isPaired: Bool,
        isConnected: Bool,
        isSustaining: Bool,
        isCapable: Bool,
        hasLargeImport: Bool,
        isPairingRefused: Bool,
        isRunning: Bool,
        lastOutcome: Outcome?,
        awaitingMarkConfirmation: Bool
    ) -> CardState {
        if isRunning { return .inProgress }
        if let lastOutcome {
            switch lastOutcome {
            case .completed: return .completed
            case .paused: return .paused
            }
        }
        if isSustaining { return .hidden }
        if awaitingMarkConfirmation || isPairingRefused { return .hidden }
        if isPaired, isConnected, isCapable, hasLargeImport { return .idle }
        return .hidden
    }

    /// Converts byte progress into bounded progress units (KiB for files > 1 KiB) that advance
    /// on every confirmed chunk without claiming 100% before every byte is confirmed.
    nonisolated static func progressUnits(bytesSent: Int64, bytesTotal: Int64) -> (completed: Int, total: Int) {
        let safeTotal = max(Int64(1), bytesTotal)
        let safeSent = min(max(Int64(0), bytesSent), safeTotal)
        if safeTotal <= 1024 {
            return (Int(safeSent), Int(safeTotal))
        }
        let totalKiB = max(1, Int((safeTotal + 1023) / 1024))
        let sentKiB = min(totalKiB, Int(safeSent / 1024))
        let clampedSent = (safeSent < safeTotal && sentKiB >= totalKiB) ? max(0, totalKiB - 1) : sentKiB
        return (clampedSent, totalKiB)
    }

    func registerLaunchHandler() {
        let didRegister = self.scheduling.register(identifier: Self.taskIdentifierPrefix + ".*") { [weak self] handle in
            guard let self else { return }
            Task { @MainActor in
                await self.runTask(handle)
            }
        }
        if !didRegister {
            self.isCapable = false
            importBgLog.error("import-background: registration failed")
        }
    }

    func submit() {
        guard case .ready = self.availability, !self.isRunning else { return }
        self.lastOutcome = nil
        let target = self.activeTarget()
        let title = AppStrings.ios_app_importbgsystemtitle()
        let subtitle: String
        if let target {
            subtitle = Self.systemSubtitle(for: target)
        } else {
            subtitle = title
        }
        let identifier = Self.taskIdentifierPrefix + "." + UUID().uuidString
        do {
            try self.scheduling.submit(
                identifier: identifier,
                title: title,
                subtitle: subtitle
            )
            self.isRunning = true
        } catch let error as BGTaskScheduler.Error {
            self.availability = .unavailable(reason: FinishSyncingCoordinator.unavailableReason(for: error.code))
            importBgLog.error("import-background: submit failed: \(String(describing: error), privacy: .public)")
        } catch {
            self.availability = .unavailable(reason: SourceVocabulary.finishSyncingUnavailableFallback)
            importBgLog.error("import-background: submit failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Invoked on every confirmed chunk ACK and phase transition from `TransferEngine`.
    /// Immediately advances `BGContinuedProcessingTask.progress` and subtitle while `runTask` is active.
    func handleResumableProgress(itemID: UUID, progress: TransferResumableProgress?) {
        guard let progress else { return }
        let filename = self.filenameForItem(itemID)
            ?? (self.lastObservedTarget?.itemID == itemID ? self.lastObservedTarget?.filename : nil)
            ?? AppStrings.ios_app_onthisphonefilelabel()
        let target = ImportBackgroundUploadTarget(
            itemID: itemID,
            filename: filename,
            bytesSent: progress.bytesSent,
            bytesTotal: progress.bytesTotal,
            phase: progress.phase
        )
        self.lastObservedTarget = target
        guard let handle = self.activeTaskHandle else { return }
        self.applyProgress(to: handle, target: target)
    }

    func runTask(_ handle: any FinishSyncingTaskHandle) async {
        self.expired = false
        handle.setExpirationHandler { [weak self] in
            self?.expired = true
        }
        self.isRunning = true
        self.isSustainingBackground = true
        self.activeTaskHandle = handle
        self.lastAppliedSystemState = nil
        defer {
            self.activeTaskHandle = nil
            self.lastAppliedSystemState = nil
            self.isSustainingBackground = false
            self.isRunning = false
        }
        await self.setPacingMode(.finishSyncing)

        if let initialTarget = self.activeTarget() ?? self.lastObservedTarget {
            self.lastObservedTarget = initialTarget
            self.applyProgress(to: handle, target: initialTarget)
        } else {
            self.lastProgressTotalUnits = 1
            handle.setProgressTotal(1)
            handle.setProgressCompleted(0)
            handle.updateTitle(
                AppStrings.ios_app_importbgsystemtitle(),
                subtitle: AppStrings.ios_app_importbgsystemtitle()
            )
        }

        var previousPending = self.pendingSendableCount()
        var lastConfirmedBytes = (self.activeTarget() ?? self.lastObservedTarget)?.bytesSent ?? 0
        var stalledRounds = 0
        var disconnectedSince: Date?

        drainLoop: while !self.expired && !handle.isCancelled && !self.isPairingRefused() {
            if let currentTarget = self.activeTarget() {
                self.lastObservedTarget = currentTarget
                self.applyProgress(to: handle, target: currentTarget)
            }

            if !self.isConnected() {
                let now = self.clock.now()
                if disconnectedSince == nil {
                    disconnectedSince = now
                    if let target = self.activeTarget() ?? self.lastObservedTarget {
                        self.applyPausedProgress(to: handle, target: target)
                    }
                }
                if let since = disconnectedSince, now.timeIntervalSince(since) >= self.reconnectGraceTimeout {
                    break drainLoop
                }
                do { try await self.clock.sleep(for: self.settleInterval) } catch { break drainLoop }
                continue drainLoop
            }

            disconnectedSince = nil
            await self.drive()
            if self.expired || handle.isCancelled || self.isPairingRefused() {
                break drainLoop
            }

            if let currentTarget = self.activeTarget() {
                self.lastObservedTarget = currentTarget
                self.applyProgress(to: handle, target: currentTarget)
                if currentTarget.bytesSent > lastConfirmedBytes {
                    lastConfirmedBytes = currentTarget.bytesSent
                    stalledRounds = 0
                }
            }

            let currentPending = self.pendingSendableCount()
            let backoff = self.backoff()
            switch evaluateDrainRound(DrainRoundInput(
                previousTotal: previousPending,
                currentTotal: currentPending,
                inFlight: self.inFlightCount(),
                stalledRounds: stalledRounds,
                backoffPendingCount: backoff.backoffPendingCount,
                endpointHeld: backoff.endpointHeld
            )) {
            case .finished, .stalled:
                break drainLoop
            case .keepGoing(let nextPrevious, let nextStalledRounds):
                previousPending = nextPrevious
                stalledRounds = nextStalledRounds
                do { try await self.clock.sleep(for: self.settleInterval) } catch { break drainLoop }
            }
        }

        let remainingPending = self.pendingSendableCount()
        let completedCleanly = !self.expired
            && !handle.isCancelled
            && !self.isPairingRefused()
            && remainingPending == 0

        if completedCleanly {
            importBgLog.info("import-background: finished sending cleanly")
            handle.setProgressTotal(self.lastProgressTotalUnits)
            handle.setProgressCompleted(self.lastProgressTotalUnits)
            let doneTitle = AppStrings.ios_app_importbgsystemdonetitle()
            handle.updateTitle(doneTitle, subtitle: self.lastObservedTarget?.filename ?? "")
            self.lastOutcome = .completed
        } else {
            if self.expired {
                importBgLog.info("import-background: paused on expiration with \(remainingPending, privacy: .public) remaining (custody and remote session preserved)")
            } else {
                importBgLog.info("import-background: paused before completion with \(remainingPending, privacy: .public) remaining")
            }
            if let target = self.activeTarget() ?? self.lastObservedTarget {
                self.applyPausedProgress(to: handle, target: target)
            } else {
                handle.updateTitle(AppStrings.ios_app_importbgsystempausedtitle(), subtitle: "")
            }
            self.lastOutcome = .paused
        }

        handle.complete(success: completedCleanly)
        await self.setPacingMode(.normal)
        self.activeTaskHandle = nil
        self.lastAppliedSystemState = nil
        self.isSustainingBackground = false
        if self.shouldDisconnectOnExit() {
            await self.disconnect()
        }
        self.isRunning = false
    }

    func dismissOutcome() {
        self.lastOutcome = nil
    }

    // MARK: - Helpers

    private nonisolated static func systemTitle(for target: ImportBackgroundUploadTarget) -> String {
        switch target.phase {
        case .sending, .checking:
            return AppStrings.ios_app_importbgsystemtitle()
        case .paused:
            return AppStrings.ios_app_importbgsystempausedtitle()
        }
    }

    private nonisolated static func systemSubtitle(for target: ImportBackgroundUploadTarget) -> String {
        let sent = ImportByteFormat.bytes(target.bytesSent)
        let total = ImportByteFormat.bytes(target.bytesTotal)
        switch target.phase {
        case .sending:
            return AppStrings.ios_app_importbgsystemsubtitle(target.filename, sent, total)
        case .checking:
            return AppStrings.ios_app_importbgsystemchecking(target.filename)
        case .paused:
            return AppStrings.ios_app_importbgsystempausedsubtitle(target.filename, sent, total)
        }
    }

    private func applyProgress(to handle: any FinishSyncingTaskHandle, target: ImportBackgroundUploadTarget) {
        let units = Self.progressUnits(bytesSent: target.bytesSent, bytesTotal: target.bytesTotal)
        let title = Self.systemTitle(for: target)
        let subtitle = Self.systemSubtitle(for: target)
        let nextState = AppliedSystemState(
            completedUnits: units.completed,
            totalUnits: units.total,
            title: title,
            subtitle: subtitle
        )
        guard nextState != self.lastAppliedSystemState else { return }
        self.lastAppliedSystemState = nextState
        self.lastProgressTotalUnits = units.total
        handle.setProgressTotal(units.total)
        handle.setProgressCompleted(units.completed)
        handle.updateTitle(title, subtitle: subtitle)
    }

    private func applyPausedProgress(to handle: any FinishSyncingTaskHandle, target: ImportBackgroundUploadTarget) {
        let pausedTarget = ImportBackgroundUploadTarget(
            itemID: target.itemID,
            filename: target.filename,
            bytesSent: target.bytesSent,
            bytesTotal: target.bytesTotal,
            phase: .paused
        )
        self.applyProgress(to: handle, target: pausedTarget)
    }
}
