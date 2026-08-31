// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity
import os

nonisolated private let watchBackgroundTaskLog = Logger(subsystem: "app.solstone.swift", category: "watch-background")

@MainActor
protocol WatchBackgroundRefreshTask: AnyObject {
    var id: ObjectIdentifier { get }
    func complete()
}

@MainActor
final class WatchBackgroundTaskCoordinator {
    private let session: any WatchConnectivitySession
    private let clock: any ObserverClock
    private let deadline: Duration
    private let storageActor: WatchCaptureStorageActor?

    private var heldTasks: [ObjectIdentifier: any WatchBackgroundRefreshTask] = [:]
    private var completedTaskIDs: Set<ObjectIdentifier> = []
    private var deadlineTask: Task<Void, Never>?

    init(
        session: any WatchConnectivitySession,
        clock: any ObserverClock = SystemObserverClock(),
        deadline: Duration = .seconds(12),
        storageActor: WatchCaptureStorageActor? = nil
    ) {
        self.session = session
        self.clock = clock
        self.deadline = deadline
        self.storageActor = storageActor
        self.session.onSessionEvent = { [weak self] in
            self?.handleSessionEvent()
        }
    }

    deinit {
        self.deadlineTask?.cancel()
    }

    func handle(_ task: any WatchBackgroundRefreshTask) {
        if self.evaluate() {
            self.complete(task, reason: "ready")
            return
        }

        guard !self.completedTaskIDs.contains(task.id) else { return }
        let didInsert = self.heldTasks.updateValue(task, forKey: task.id) == nil
        if didInsert {
            watchBackgroundTaskLog.debug("watch background: held task count=\(self.heldTasks.count, privacy: .public)")
        }
        self.armDeadlineIfNeeded()
    }
}

private extension WatchBackgroundTaskCoordinator {
    func handleSessionEvent() {
        guard self.evaluate() else { return }
        self.completeAllHeld(reason: "session-ready")
    }

    func evaluate() -> Bool {
        self.session.activationState == .activated && self.session.hasContentPending == false
    }

    func complete(_ task: any WatchBackgroundRefreshTask, reason: String) {
        guard !self.completedTaskIDs.contains(task.id) else { return }
        self.heldTasks.removeValue(forKey: task.id)
        self.completedTaskIDs.insert(task.id)
        task.complete()
        if let storageActor {
            Task { @MainActor in
                await storageActor.recordRelayBackgroundWake(
                    reason: reason,
                    heldTaskCount: self.heldTasks.count,
                    completedTaskCount: self.completedTaskIDs.count,
                    deadlineCount: reason == "deadline" ? 1 : 0,
                    at: self.clock.now()
                )
            }
        }
        watchBackgroundTaskLog.debug("watch background: completed task reason=\(reason, privacy: .public) remaining=\(self.heldTasks.count, privacy: .public)")
        self.cancelDeadlineIfIdle()
    }

    func completeAllHeld(reason: String) {
        let tasks = Array(self.heldTasks.values)
        guard !tasks.isEmpty else {
            self.cancelDeadlineIfIdle()
            return
        }
        for task in tasks {
            self.complete(task, reason: reason)
        }
    }

    func armDeadlineIfNeeded() {
        guard self.deadlineTask == nil else { return }
        let clock = self.clock
        let deadline = self.deadline
        watchBackgroundTaskLog.debug("watch background: deadline armed")
        self.deadlineTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: deadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            watchBackgroundTaskLog.info("watch background: deadline completing held tasks count=\(self.heldTasks.count, privacy: .public)")
            self.deadlineTask = nil
            self.completeAllHeld(reason: "deadline")
        }
    }

    // W2 has late session events and coalesced tasks, so completion is guarded explicitly.
    func cancelDeadlineIfIdle() {
        guard self.heldTasks.isEmpty else { return }
        self.deadlineTask?.cancel()
        self.deadlineTask = nil
    }
}
