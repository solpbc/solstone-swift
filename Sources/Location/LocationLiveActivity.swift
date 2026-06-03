// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ActivityKit
import Foundation
import os

nonisolated struct LocationActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        let tierLabel: String
        let segmentCount: Int
    }

    let sessionID: String
}

protocol LocationLiveActivitying: AnyObject {
    func start(tierLabel: String, sessionID: String) async
    func update(tierLabel: String, segmentCount: Int) async
    func end() async
}

actor LocationLiveActivity: LocationLiveActivitying {
    private let log = Logger(subsystem: "app.solstone.swift", category: "liveactivity")
    private var activitySessionID: String?

    func start(tierLabel: String, sessionID: String) async {
        if let activitySessionID {
            await Self.endActivity(sessionID: activitySessionID)
            self.activitySessionID = nil
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            self.log.error("location live activity unavailable")
            return
        }

        do {
            let activity = try Activity.request(
                attributes: LocationActivityAttributes(sessionID: sessionID),
                content: ActivityContent(
                    state: LocationActivityAttributes.ContentState(tierLabel: tierLabel, segmentCount: 0),
                    staleDate: nil
                )
            )
            self.activitySessionID = activity.attributes.sessionID
        } catch {
            self.log.error("location live activity start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func update(tierLabel: String, segmentCount: Int) async {
        guard let activitySessionID else { return }
        await Self.updateActivity(
            sessionID: activitySessionID,
            content: ActivityContent(
                state: LocationActivityAttributes.ContentState(tierLabel: tierLabel, segmentCount: segmentCount),
                staleDate: nil
            )
        )
    }

    func end() async {
        guard let activitySessionID else { return }
        await Self.endActivity(sessionID: activitySessionID)
        self.activitySessionID = nil
    }

    nonisolated private static func updateActivity(
        sessionID: String,
        content: ActivityContent<LocationActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<LocationActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) else { return }
        await activity.update(content)
    }

    nonisolated private static func endActivity(sessionID: String) async {
        guard let activity = Activity<LocationActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
