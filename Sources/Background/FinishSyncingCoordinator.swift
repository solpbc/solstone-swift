// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import BackgroundTasks
import Foundation
import Observation
import UIKit
import os

private let finishSyncingLog = Logger(subsystem: "app.solstone.swift", category: "finish-syncing")

@MainActor
protocol FinishSyncingTaskHandle: AnyObject {
    var isCancelled: Bool { get }
    func setProgressTotal(_ total: Int)
    func setProgressCompleted(_ completed: Int)
    func updateTitle(_ title: String, subtitle: String)
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void)
    func complete(success: Bool)
}

@MainActor
protocol FinishSyncingScheduling {
    func register(identifier: String, launchHandler: @escaping @MainActor (any FinishSyncingTaskHandle) -> Void) -> Bool
    func submit(identifier: String, title: String, subtitle: String) throws
}

@MainActor
final class BGTaskSchedulerAdapter: FinishSyncingScheduling {
    func register(identifier: String, launchHandler: @escaping @MainActor (any FinishSyncingTaskHandle) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            MainActor.assumeIsolated {
                guard let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                launchHandler(BGContinuedProcessingTaskHandle(continuedTask))
            }
        }
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .queue
        request.requiredResources = []
        try BGTaskScheduler.shared.submit(request)
    }
}

@MainActor
final class BGContinuedProcessingTaskHandle: FinishSyncingTaskHandle {
    private let task: BGContinuedProcessingTask

    init(_ task: BGContinuedProcessingTask) {
        self.task = task
    }

    var isCancelled: Bool {
        self.task.progress.isCancelled
    }

    func setProgressTotal(_ total: Int) {
        self.task.progress.totalUnitCount = Int64(total)
    }

    func setProgressCompleted(_ completed: Int) {
        self.task.progress.completedUnitCount = Int64(completed)
    }

    func updateTitle(_ title: String, subtitle: String) {
        self.task.updateTitle(title, subtitle: subtitle)
    }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        self.task.expirationHandler = {
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    func complete(success: Bool) {
        self.task.setTaskCompleted(success: success)
    }
}

@MainActor
@Observable
final class FinishSyncingCoordinator {
    static let backlogThreshold = 25
    static let taskIdentifierPrefix = "app.solstone.swift.finish-syncing"

    enum Availability: Equatable {
        case ready
        case unavailable(reason: String)
    }

    enum Outcome: Equatable {
        case completed
        case interrupted(remaining: Int)
    }

    enum CardState: Equatable {
        case hidden
        case idle
        case inProgress
        case completed
        case interrupted(remaining: Int)
    }

    private(set) var availability: Availability = .ready
    private(set) var isCapable: Bool = true
    private(set) var isFinishing = false
    private(set) var lastOutcome: Outcome?

    @ObservationIgnored private let totals: () -> (failed: Int, pending: Int)
    @ObservationIgnored private let inFlight: () -> Int
    @ObservationIgnored private let drive: () async -> Void
    @ObservationIgnored private let isConnected: () -> Bool
    @ObservationIgnored private let disconnect: () async -> Void
    @ObservationIgnored private let scheduling: any FinishSyncingScheduling
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let settleInterval: Duration
    @ObservationIgnored private var expired = false

    init(
        totals: @escaping () -> (failed: Int, pending: Int),
        inFlight: @escaping () -> Int,
        drive: @escaping () async -> Void,
        isConnected: @escaping () -> Bool,
        disconnect: @escaping () async -> Void,
        scheduling: any FinishSyncingScheduling = BGTaskSchedulerAdapter(),
        clock: any ObserverClock = SystemObserverClock(),
        settleInterval: Duration = .seconds(2)
    ) {
        self.totals = totals
        self.inFlight = inFlight
        self.drive = drive
        self.isConnected = isConnected
        self.disconnect = disconnect
        self.scheduling = scheduling
        self.clock = clock
        self.settleInterval = settleInterval
    }

    nonisolated static func cardState(
        isPaired: Bool,
        isConnected: Bool,
        isSustaining: Bool,
        isCapable: Bool,
        backlog: Int,
        isFinishing: Bool,
        lastOutcome: Outcome?,
        threshold: Int
    ) -> CardState {
        if isFinishing { return .inProgress }
        if let lastOutcome {
            switch lastOutcome {
            case .completed: return .completed
            case .interrupted(let remaining): return .interrupted(remaining: remaining)
            }
        }
        if isSustaining { return .hidden }
        if isPaired, isConnected, isCapable, backlog >= threshold { return .idle }
        return .hidden
    }

    nonisolated static func unavailableReason(for code: BGTaskScheduler.Error.Code) -> String {
        switch code {
        case .unavailable: return SourceVocabulary.finishSyncingUnavailableUnavailable
        case .notPermitted: return SourceVocabulary.finishSyncingUnavailableNotPermitted
        case .tooManyPendingTaskRequests: return SourceVocabulary.finishSyncingUnavailableTooManyPending
        case .immediateRunIneligible: return SourceVocabulary.finishSyncingUnavailableImmediateIneligible
        @unknown default: return SourceVocabulary.finishSyncingUnavailableFallback
        }
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
            finishSyncingLog.error("finish-syncing: registration failed")
        }
    }

    func submit() {
        guard case .ready = self.availability else { return }
        self.lastOutcome = nil
        let remaining = self.totals()
        let backlog = remaining.failed + remaining.pending
        let identifier = Self.taskIdentifierPrefix + "." + UUID().uuidString
        do {
            try self.scheduling.submit(
                identifier: identifier,
                title: SourceVocabulary.finishSyncingSystemTitle,
                subtitle: SourceVocabulary.finishSyncingSystemSubtitle(remaining: backlog)
            )
            self.isFinishing = true
        } catch let error as BGTaskScheduler.Error {
            self.availability = .unavailable(reason: Self.unavailableReason(for: error.code))
            finishSyncingLog.error("finish-syncing: submit failed: \(String(describing: error), privacy: .public)")
        } catch {
            self.availability = .unavailable(reason: SourceVocabulary.finishSyncingUnavailableFallback)
            finishSyncingLog.error("finish-syncing: submit failed: \(String(describing: error), privacy: .public)")
        }
    }

    func runTask(_ handle: any FinishSyncingTaskHandle) async {
        self.expired = false
        handle.setExpirationHandler { [weak self] in
            self?.expired = true
        }
        self.isFinishing = true

        let initial = self.totals()
        let backlog = initial.failed + initial.pending
        handle.setProgressTotal(backlog)
        handle.setProgressCompleted(0)
        handle.updateTitle(
            SourceVocabulary.finishSyncingSystemTitle,
            subtitle: SourceVocabulary.finishSyncingSystemSubtitle(remaining: backlog)
        )

        var previous = backlog
        var stalledRounds = 0
        while self.isConnected(), !self.expired && !handle.isCancelled {
            await self.drive()
            if self.expired || handle.isCancelled { break }
            let current = self.totals()
            let total = current.failed + current.pending
            handle.setProgressCompleted(max(0, backlog - total))
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

        let exitInFlight = self.inFlight()
        if self.expired {
            finishSyncingLog.info("finish-syncing: stopped at expiration with \(exitInFlight, privacy: .public) in-flight")
        } else {
            finishSyncingLog.info("finish-syncing: clean quiesce (in-flight \(exitInFlight, privacy: .public))")
        }
        let final = self.totals()
        let remaining = final.failed + final.pending
        let success = remaining == 0
        if success {
            handle.updateTitle(
                SourceVocabulary.finishSyncingSystemDoneTitle,
                subtitle: SourceVocabulary.finishSyncingSystemSubtitle(remaining: 0)
            )
            self.lastOutcome = .completed
        } else {
            handle.updateTitle(
                SourceVocabulary.finishSyncingSystemPausedTitle,
                subtitle: SourceVocabulary.finishSyncingSystemSubtitle(remaining: remaining)
            )
            self.lastOutcome = .interrupted(remaining: remaining)
        }
        handle.complete(success: success)
        await self.disconnect()
        self.isFinishing = false
    }

    func dismissOutcome() {
        self.lastOutcome = nil
    }
}
