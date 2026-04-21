// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ActivityKit
import Foundation
import os

nonisolated struct ObserverActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        let elapsed: TimeInterval
        let mode: String
    }

    let sessionID: String
}

protocol ObserverLiveActivitying: AnyObject {
    func start(mode: ObserverMode, sessionID: UUID, elapsed: TimeInterval) async
    func update(mode: ObserverMode, elapsed: TimeInterval) async
    func end(mode: ObserverMode, elapsed: TimeInterval) async
}

actor ObserverLiveActivity: ObserverLiveActivitying {
    private let log = Logger(subsystem: "app.solstone.swift", category: "liveactivity")
    private var activitySessionID: String?

    func start(mode: ObserverMode, sessionID: UUID, elapsed: TimeInterval) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            self.log.error("observer live activity unavailable")
            return
        }

        do {
            let activity = try Activity.request(
                attributes: ObserverActivityAttributes(sessionID: sessionID.uuidString),
                content: ActivityContent(
                    state: ObserverActivityAttributes.ContentState(elapsed: elapsed, mode: mode.rawValue),
                    staleDate: nil
                )
            )
            self.activitySessionID = activity.attributes.sessionID
        } catch {
            self.log.error("observer live activity start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func update(mode: ObserverMode, elapsed: TimeInterval) async {
        guard let activitySessionID else { return }
        await Self.updateActivity(
            sessionID: activitySessionID,
            content: ActivityContent(
                state: ObserverActivityAttributes.ContentState(elapsed: elapsed, mode: mode.rawValue),
                staleDate: nil
            )
        )
    }

    func end(mode: ObserverMode, elapsed: TimeInterval) async {
        guard let activitySessionID else { return }
        await Self.endActivity(
            sessionID: activitySessionID,
            content: ActivityContent(
                state: ObserverActivityAttributes.ContentState(elapsed: elapsed, mode: mode.rawValue),
                staleDate: nil
            )
        )
        self.activitySessionID = nil
    }

    nonisolated private static func updateActivity(
        sessionID: String,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<ObserverActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) else { return }
        await activity.update(content)
    }

    nonisolated private static func endActivity(
        sessionID: String,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<ObserverActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) else { return }
        await activity.end(content, dismissalPolicy: .immediate)
    }
}

nonisolated func observerModeLabel(for rawMode: String) -> String {
    switch rawMode {
    case "meeting":
        "Meeting"
    case "voice_memo":
        "Voice memo"
    default:
        "Listening"
    }
}
