// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import ActivityKit
import Foundation
import XCTest

@MainActor
final class ObserverLiveActivityCutoffTests: XCTestCase {
    func testWarningPrecedesSelfEndWithFinalContentAtCutoff() async {
        let clock = MockObserverClock(now: Self.startDate)
        let port = FakeObserverLiveActivityPort()
        let scheduler = FakeObserverLiveActivityWarningScheduler(isAuthorized: true)
        let activity = self.makeActivity(clock: clock, port: port, scheduler: scheduler)
        let sessionID = UUID()

        await activity.start(mode: .meeting, sessionID: sessionID, startedAt: Self.startDate)
        await self.waitForSleeper(in: clock)

        clock.advance(by: 6)
        await self.drainTasks()
        let warningsBeforeLead = await scheduler.warningSessions()
        let endsBeforeLead = await port.endCalls()
        XCTAssertTrue(warningsBeforeLead.isEmpty)
        XCTAssertTrue(endsBeforeLead.isEmpty)

        clock.advance(by: 1)
        await self.waitForSleeper(in: clock)
        let warningSessions = await scheduler.warningSessions()
        let endsBeforeCutoff = await port.endCalls()
        XCTAssertEqual(warningSessions, [sessionID])
        XCTAssertTrue(endsBeforeCutoff.isEmpty)

        clock.advance(by: 3)
        await self.drainTasks()

        let endCalls = await port.endCalls()
        XCTAssertEqual(endCalls.count, 1)
        XCTAssertEqual(endCalls.first?.sessionID, sessionID.uuidString)
        XCTAssertEqual(endCalls.first?.contentState.startedAt, Self.startDate)
        XCTAssertEqual(endCalls.first?.contentState.mode, ObserverMode.meeting.rawValue)
        XCTAssertEqual(endCalls.first?.staleDate, clock.now())
    }

    func testNormalEndCancelsPendingWarningAndCutoff() async {
        let clock = MockObserverClock(now: Self.startDate)
        let port = FakeObserverLiveActivityPort()
        let scheduler = FakeObserverLiveActivityWarningScheduler(isAuthorized: true)
        let activity = self.makeActivity(clock: clock, port: port, scheduler: scheduler)
        let sessionID = UUID()

        await activity.start(mode: .meeting, sessionID: sessionID, startedAt: Self.startDate)
        await self.waitForSleeper(in: clock)
        clock.advance(by: 6)
        await self.drainTasks()

        await activity.end(sessionID: sessionID)
        clock.advance(by: 4)
        await self.drainTasks()

        let warningSessions = await scheduler.warningSessions()
        let endCalls = await port.endCalls()
        XCTAssertTrue(warningSessions.isEmpty)
        XCTAssertEqual(endCalls.count, 1)
    }

    func testRearmCreatesFreshActivityWithOriginalStartAnchor() async {
        let clock = MockObserverClock(now: Self.startDate)
        let port = FakeObserverLiveActivityPort()
        let scheduler = FakeObserverLiveActivityWarningScheduler(isAuthorized: true)
        let activity = self.makeActivity(clock: clock, port: port, scheduler: scheduler)
        let sessionID = UUID()

        await activity.start(mode: .voiceMemo, sessionID: sessionID, startedAt: Self.startDate)
        await activity.end(sessionID: sessionID)
        clock.advance(by: 1)
        await activity.start(mode: .voiceMemo, sessionID: sessionID, startedAt: Self.startDate)

        let requests = await port.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.contentState.startedAt), [Self.startDate, Self.startDate])
        XCTAssertEqual(requests.map(\.contentState.mode), [ObserverMode.voiceMemo.rawValue, ObserverMode.voiceMemo.rawValue])
    }

    func testEndAllUsesEachActivitiesFinalContent() async {
        let clock = MockObserverClock(now: Self.startDate)
        let port = FakeObserverLiveActivityPort()
        let scheduler = FakeObserverLiveActivityWarningScheduler(isAuthorized: true)
        let activity = self.makeActivity(clock: clock, port: port, scheduler: scheduler)
        let sessionID = UUID()
        let contentState = ObserverActivityAttributes.ContentState(
            startedAt: Self.startDate.addingTimeInterval(-12),
            mode: ObserverMode.meeting.rawValue
        )
        await port.seed(sessionID: sessionID.uuidString, contentState: contentState)

        await activity.endAll()

        let endCalls = await port.endCalls()
        XCTAssertEqual(endCalls.count, 1)
        XCTAssertEqual(endCalls.first?.contentState, contentState)
        XCTAssertEqual(endCalls.first?.staleDate, Self.startDate)
    }

    func testNotificationsUnavailableSkipsWarningAndStillSelfEnds() async {
        let clock = MockObserverClock(now: Self.startDate)
        let port = FakeObserverLiveActivityPort()
        let scheduler = FakeObserverLiveActivityWarningScheduler(isAuthorized: false)
        let activity = self.makeActivity(clock: clock, port: port, scheduler: scheduler)
        let sessionID = UUID()

        await activity.start(mode: .meeting, sessionID: sessionID, startedAt: Self.startDate)
        await self.waitForSleeper(in: clock)
        clock.advance(by: 7)
        await self.waitForSleeper(in: clock)
        clock.advance(by: 3)
        await self.drainTasks()

        let warningSessions = await scheduler.warningSessions()
        let endCalls = await port.endCalls()
        XCTAssertTrue(warningSessions.isEmpty)
        XCTAssertEqual(endCalls.count, 1)
    }
}

private extension ObserverLiveActivityCutoffTests {
    static let startDate = Date(timeIntervalSince1970: 1_713_624_000)

    func makeActivity(
        clock: MockObserverClock,
        port: FakeObserverLiveActivityPort,
        scheduler: FakeObserverLiveActivityWarningScheduler
    ) -> ObserverLiveActivity {
        ObserverLiveActivity(
            clock: clock,
            policy: ObserverLiveActivityCutoffPolicy(
                maximumActivityDuration: .seconds(10),
                warningLeadTime: .seconds(3),
                skipWarningWhenNotificationsAreUnavailable: true
            ),
            port: port,
            warningScheduler: scheduler
        )
    }

    func waitForSleeper(in clock: MockObserverClock) async {
        for _ in 0..<100 {
            if clock.pendingSleeperCount > 0 {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected cutoff task to begin sleeping")
    }

    func drainTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

private actor FakeObserverLiveActivityPort: ObserverLiveActivityPort {
    struct Request: Equatable, Sendable {
        let sessionID: String
        let contentState: ObserverActivityAttributes.ContentState
        let staleDate: Date?
    }

    struct EndCall: Equatable, Sendable {
        let sessionID: String
        let contentState: ObserverActivityAttributes.ContentState
        let staleDate: Date?
    }

    private var activities: [String: ActivityContent<ObserverActivityAttributes.ContentState>] = [:]
    private var recordedRequests: [Request] = []
    private var recordedEndCalls: [EndCall] = []

    func request(
        attributes: ObserverActivityAttributes,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async throws {
        self.activities[attributes.sessionID] = content
        self.recordedRequests.append(Request(
            sessionID: attributes.sessionID,
            contentState: content.state,
            staleDate: content.staleDate
        ))
    }

    func content(
        sessionID: String
    ) async -> ActivityContent<ObserverActivityAttributes.ContentState>? {
        self.activities[sessionID]
    }

    func end(
        sessionID: String,
        content: ActivityContent<ObserverActivityAttributes.ContentState>
    ) async {
        self.activities.removeValue(forKey: sessionID)
        self.recordedEndCalls.append(EndCall(
            sessionID: sessionID,
            contentState: content.state,
            staleDate: content.staleDate
        ))
    }

    func endAll(staleDate: Date) async {
        for (sessionID, content) in self.activities {
            self.recordedEndCalls.append(EndCall(
                sessionID: sessionID,
                contentState: content.state,
                staleDate: staleDate
            ))
        }
        self.activities.removeAll()
    }

    func seed(sessionID: String, contentState: ObserverActivityAttributes.ContentState) {
        self.activities[sessionID] = ActivityContent(state: contentState, staleDate: nil)
    }

    func requests() -> [Request] {
        self.recordedRequests
    }

    func endCalls() -> [EndCall] {
        self.recordedEndCalls
    }
}

private actor FakeObserverLiveActivityWarningScheduler: ObserverLiveActivityWarningScheduling {
    private let authorized: Bool
    private var recordedWarningSessions: [UUID] = []

    init(isAuthorized: Bool) {
        self.authorized = isAuthorized
    }

    func isAuthorizedForAlerts() async -> Bool {
        self.authorized
    }

    func scheduleWarning(for sessionID: UUID) async {
        self.recordedWarningSessions.append(sessionID)
    }

    func warningSessions() -> [UUID] {
        self.recordedWarningSessions
    }
}
