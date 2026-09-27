// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class HomeStatusPillStateTests: XCTestCase {
    func testResolveCoversEveryConnectionStatusAndInputCombination() {
        let statuses: [ConnectionSyncStatus] = [
            .offline,
            .connecting,
            .waitingForHome,
            .reconnecting,
            .unreachable,
            .connectedIdle,
            .connectedWaiting,
            .connectedTransferring,
        ]

        for isPaired in [false, true] {
            for hasBacklog in [false, true] {
                for status in statuses {
                    XCTAssertEqual(
                        HomeStatusPillState.resolve(
                            isPaired: isPaired,
                            status: status,
                            hasBacklog: hasBacklog,
                            isStalled: false
                        ),
                        Self.expectedState(
                            isPaired: isPaired,
                            status: status,
                            hasBacklog: hasBacklog
                        ),
                        "isPaired=\(isPaired) hasBacklog=\(hasBacklog) status=\(status)"
                    )
                }
            }
        }
    }

    func testResolveWhenStalled() {
        let statuses: [ConnectionSyncStatus] = [
            .offline,
            .connecting,
            .waitingForHome,
            .reconnecting,
            .unreachable,
            .connectedIdle,
            .connectedWaiting,
            .connectedTransferring,
        ]

        for hasBacklog in [false, true] {
            for status in statuses {
                let state = HomeStatusPillState.resolve(
                    isPaired: true,
                    status: status,
                    hasBacklog: hasBacklog,
                    isStalled: true
                )
                XCTAssertEqual(state, .stalled)
                XCTAssertEqual(
                    state.label(hasBacklog: hasBacklog),
                    hasBacklog ? SourceVocabulary.stallWaitingLabel : SourceVocabulary.stallNotConnectedLabel
                )

                let unpairedState = HomeStatusPillState.resolve(
                    isPaired: false,
                    status: status,
                    hasBacklog: hasBacklog,
                    isStalled: true
                )
                XCTAssertEqual(unpairedState, .notPaired)
                XCTAssertEqual(unpairedState.label(hasBacklog: hasBacklog), SourceVocabulary.dayLocalityNoJournal)
            }
        }
    }

    func testCollapsedLabelsDoNotLeakRawConnectingOrUnreachableStatusLines() {
        for status in [ConnectionSyncStatus.waitingForHome, .reconnecting, .unreachable] {
            let state = HomeStatusPillState.resolve(isPaired: true, status: status, hasBacklog: false, isStalled: false)
            XCTAssertEqual(state.label, SourceVocabulary.statusConnectingLabel)
            XCTAssertNotEqual(state.label, status.statusLine)
        }
    }

    func testShouldPulseBehavior() {
        let allStates: [HomeStatusPillState] = [
            .caughtUp,
            .syncing,
            .connecting,
            .offline,
            .notPaired,
            .stalled,
        ]

        for state in allStates {
            XCTAssertFalse(state.shouldPulse(reduceMotion: true), "state=\(state) must not pulse when reduceMotion is true")
            if case .syncing = state {
                XCTAssertTrue(state.shouldPulse(reduceMotion: false), "syncing state must pulse when reduceMotion is false")
            } else {
                XCTAssertFalse(state.shouldPulse(reduceMotion: false), "state=\(state) must not pulse when reduceMotion is false")
            }
        }
    }

    func testHomeAndStatusPaneResolvePillStateFromSharedConnectionInputs() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let dayHome = try String(
            contentsOf: root.appendingPathComponent("Sources/Home/DayHomeView.swift"),
            encoding: .utf8
        )
        let statusPane = try String(
            contentsOf: root.appendingPathComponent("Sources/Home/StatusPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(dayHome.contains("HomeStatusPillState.resolve("))
        XCTAssertTrue(statusPane.contains("HomeStatusPillState.resolve("))
        for input in ["isPaired: self.appConfig.isPaired", "status: self.connectionSyncModel.status"] {
            XCTAssertTrue(dayHome.contains(input), input)
            XCTAssertTrue(statusPane.contains(input), input)
        }
    }

    private static func expectedState(
        isPaired: Bool,
        status: ConnectionSyncStatus,
        hasBacklog: Bool
    ) -> HomeStatusPillState {
        guard isPaired else { return .notPaired }
        switch status {
        case .connectedIdle, .connectedWaiting, .connectedTransferring:
            return hasBacklog ? .syncing : .caughtUp
        case .connecting, .waitingForHome, .reconnecting, .unreachable:
            return .connecting
        case .offline:
            return .offline
        }
    }
}
