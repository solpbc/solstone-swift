// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ActivityKit
import Foundation
import UserNotifications
import os

nonisolated struct ObserverActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        let startedAt: Date
        let mode: String
    }

    let sessionID: String
}

nonisolated struct ObserverLiveActivityCutoffPolicy: Sendable {
    let maximumActivityDuration: Duration
    let warningLeadTime: Duration
    let skipWarningWhenNotificationsAreUnavailable: Bool

    static let `default` = Self(
        maximumActivityDuration: .seconds(27_000),
        warningLeadTime: .seconds(900),
        skipWarningWhenNotificationsAreUnavailable: true
    )
}

nonisolated protocol ObserverLiveActivityPort: Sendable {
    func request(
        attributes: ObserverActivityAttributes,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async throws
    func content(
        sessionID: String
    ) async -> ActivityContent<ObserverActivityAttributes.ContentState>?
    func end(
        sessionID: String,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async
    func endAll(staleDate: Date) async
}

nonisolated protocol ObserverLiveActivityWarningScheduling: Sendable {
    func isAuthorizedForAlerts() async -> Bool
    func scheduleWarning(for sessionID: UUID) async
}

nonisolated enum ObserverLiveActivityWarningNotification {
    static let categoryIdentifier = "SOLSTONE_OBSERVER_ACTIVITY_REARM"

    static func identifier(for sessionID: UUID) -> String {
        "observer-live-activity-warning-\(sessionID.uuidString)"
    }
}

actor SystemObserverLiveActivityPort: ObserverLiveActivityPort {
    func request(
        attributes: ObserverActivityAttributes,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ObserverLiveActivityPortError.unavailable
        }
        _ = try Activity.request(attributes: attributes, content: content)
    }

    func content(
        sessionID: String
    ) async -> ActivityContent<ObserverActivityAttributes.ContentState>? {
        Activity<ObserverActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        })?.content
    }

    func end(
        sessionID: String,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<ObserverActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) else { return }
        await activity.end(content, dismissalPolicy: .default)
    }

    func endAll(staleDate: Date) async {
        for activity in Activity<ObserverActivityAttributes>.activities {
            let content = ActivityContent(state: activity.content.state, staleDate: staleDate)
            await activity.end(content, dismissalPolicy: .default)
        }
    }
}

actor SystemObserverLiveActivityWarningScheduler: ObserverLiveActivityWarningScheduling {
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "app.solstone.swift", category: "liveactivity")

    func isAuthorizedForAlerts() async -> Bool {
        let settings = await self.center.notificationSettings()
        return switch settings.authorizationStatus {
        case .authorized, .ephemeral, .provisional:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    func scheduleWarning(for sessionID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = "tbd: activity ending soon"
        content.body = "tbd: tap to keep this session visible"
        content.categoryIdentifier = ObserverLiveActivityWarningNotification.categoryIdentifier
        let request = UNNotificationRequest(
            identifier: ObserverLiveActivityWarningNotification.identifier(for: sessionID),
            content: content,
            trigger: nil
        )

        do {
            try await self.center.add(request)
        } catch {
            self.log.error("observer live activity warning schedule failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private enum ObserverLiveActivityPortError: Error {
    case unavailable
}

protocol ObserverLiveActivitying: AnyObject {
    func start(mode: ObserverMode, sessionID: UUID, startedAt: Date) async
    func end(sessionID: UUID) async
    func endAll() async
}

actor ObserverLiveActivity: ObserverLiveActivitying {
    private struct TrackedActivity {
        let contentState: ObserverActivityAttributes.ContentState
        let generation: UUID
        let cutoffTask: Task<Void, Never>
    }

    private let log = Logger(subsystem: "app.solstone.swift", category: "liveactivity")
    private let clock: any ObserverClock
    private let policy: ObserverLiveActivityCutoffPolicy
    private let port: any ObserverLiveActivityPort
    private let warningScheduler: any ObserverLiveActivityWarningScheduling
    private var trackedActivities: [UUID: TrackedActivity] = [:]

    init(
        clock: any ObserverClock = SystemObserverClock(),
        policy: ObserverLiveActivityCutoffPolicy = .default,
        port: any ObserverLiveActivityPort = SystemObserverLiveActivityPort(),
        warningScheduler: any ObserverLiveActivityWarningScheduling = SystemObserverLiveActivityWarningScheduler()
    ) {
        self.clock = clock
        self.policy = policy
        self.port = port
        self.warningScheduler = warningScheduler
    }

    func start(mode: ObserverMode, sessionID: UUID, startedAt: Date) async {
        await self.endAll()

        let contentState = ObserverActivityAttributes.ContentState(
            startedAt: startedAt,
            mode: mode.rawValue
        )
        let content = self.content(for: contentState, staleDate: await self.cutoffStaleDate())

        do {
            try await self.port.request(
                attributes: ObserverActivityAttributes(sessionID: sessionID.uuidString),
                content: content
            )
        } catch {
            self.log.error("observer live activity start failed: \(String(describing: error), privacy: .public)")
            return
        }

        self.armCutoff(for: sessionID, contentState: contentState)
    }

    func end(sessionID: UUID) async {
        let tracked = self.trackedActivities.removeValue(forKey: sessionID)
        tracked?.cutoffTask.cancel()

        let contentState: ObserverActivityAttributes.ContentState?
        if let tracked {
            contentState = tracked.contentState
        } else {
            contentState = await self.port.content(sessionID: sessionID.uuidString)?.state
        }
        guard let contentState else { return }

        let staleDate = await self.now()
        await self.port.end(
            sessionID: sessionID.uuidString,
            content: self.content(for: contentState, staleDate: staleDate)
        )
    }

    func endAll() async {
        let tracked = self.trackedActivities
        self.trackedActivities.removeAll()
        for activity in tracked.values {
            activity.cutoffTask.cancel()
        }
        await self.port.endAll(staleDate: await self.now())
    }
}

private extension ObserverLiveActivity {
    func armCutoff(
        for sessionID: UUID,
        contentState: ObserverActivityAttributes.ContentState
    ) {
        let generation = UUID()
        let cutoffTask = Task { [weak self] in
            guard let self else { return }
            await self.runCutoff(
                for: sessionID,
                contentState: contentState,
                generation: generation
            )
        }
        self.trackedActivities[sessionID] = TrackedActivity(
            contentState: contentState,
            generation: generation,
            cutoffTask: cutoffTask
        )
    }

    func runCutoff(
        for sessionID: UUID,
        contentState: ObserverActivityAttributes.ContentState,
        generation: UUID
    ) async {
        do {
            try await self.clock.sleep(for: self.policy.maximumActivityDuration - self.policy.warningLeadTime)
        } catch {
            return
        }
        guard self.isCurrent(sessionID: sessionID, generation: generation) else { return }

        let shouldScheduleWarning: Bool
        if self.policy.skipWarningWhenNotificationsAreUnavailable {
            shouldScheduleWarning = await self.warningScheduler.isAuthorizedForAlerts()
        } else {
            shouldScheduleWarning = true
        }
        if shouldScheduleWarning {
            await self.warningScheduler.scheduleWarning(for: sessionID)
        }

        do {
            try await self.clock.sleep(for: self.policy.warningLeadTime)
        } catch {
            return
        }
        guard self.isCurrent(sessionID: sessionID, generation: generation) else { return }

        self.trackedActivities.removeValue(forKey: sessionID)
        let staleDate = await self.now()
        await self.port.end(
            sessionID: sessionID.uuidString,
            content: self.content(for: contentState, staleDate: staleDate)
        )
    }

    func isCurrent(sessionID: UUID, generation: UUID) -> Bool {
        self.trackedActivities[sessionID]?.generation == generation
    }

    func content(
        for state: ObserverActivityAttributes.ContentState,
        staleDate: Date
    ) -> ActivityContent<ObserverActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: staleDate)
    }

    func now() async -> Date {
        let clock = self.clock
        return await MainActor.run {
            clock.now()
        }
    }

    func cutoffStaleDate() async -> Date {
        let now = await self.now()
        return now.addingTimeInterval(Self.timeInterval(self.policy.maximumActivityDuration))
    }

    nonisolated static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

nonisolated func observerModeLabel(for rawMode: String) -> String {
    "on"
}
