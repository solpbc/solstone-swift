// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import BackgroundTasks
import Foundation
import os

nonisolated private let calendarRefreshLog = Logger(subsystem: "app.solstone.swift", category: "calendar")

/// Background refresh time for the calendar source. iOS never wakes an app when a calendar
/// changes; refresh time it grants is one more moment the source checks. Nothing is asked for
/// until the source is set up.
@MainActor
final class CalendarBackgroundRefresh {
    static let identifier = "app.solstone.swift.calendar-refresh"
    static let interval: TimeInterval = 60 * 60

    private let engine: CalendarSourceEngine

    init(engine: CalendarSourceEngine) {
        self.engine = engine
    }

    func register() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                self?.run(CalendarRefreshTaskHandle(task))
            }
        }
        if !registered {
            calendarRefreshLog.error("calendar refresh registration failed")
        }
    }

    func schedule() {
        guard self.engine.wantsBackgroundRefresh else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            calendarRefreshLog.notice("calendar refresh not scheduled: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func run(_ handle: CalendarRefreshTaskHandle) {
        self.schedule()
        let engine = self.engine
        let work = Task { @MainActor in
            let checked = await engine.backgroundRefresh()
            handle.complete(success: checked && !Task.isCancelled)
        }
        handle.setExpirationHandler {
            work.cancel()
            Task { @MainActor in
                handle.complete(success: false)
            }
        }
    }
}

@MainActor
private final class CalendarRefreshTaskHandle {
    private let task: BGTask
    private var completed = false

    init(_ task: BGTask) {
        self.task = task
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        self.task.expirationHandler = handler
    }

    func complete(success: Bool) {
        guard !self.completed else { return }
        self.completed = true
        self.task.setTaskCompleted(success: success)
    }
}
