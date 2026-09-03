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
                            hasBacklog: hasBacklog
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

    func testCollapsedLabelsDoNotLeakRawConnectingOrUnreachableStatusLines() {
        for status in [ConnectionSyncStatus.waitingForHome, .reconnecting, .unreachable] {
            let state = HomeStatusPillState.resolve(isPaired: true, status: status, hasBacklog: false)
            XCTAssertEqual(state.label, SourceVocabulary.statusConnectingLabel)
            XCTAssertNotEqual(state.label, status.statusLine)
        }
    }

    func testConnectingDotStaysCalmAndSecondary() throws {
        let text = try String(
            contentsOf: StringLiteralGrepSupport.worktreeRoot()
                .appendingPathComponent("Sources/Home/HomeStatusPill.swift"),
            encoding: .utf8
        )
        let pulseStart = try XCTUnwrap(text.range(of: "private var shouldPulse: Bool {"))
        let tintStart = try XCTUnwrap(text.range(of: "private var tint: Color {", range: pulseStart.upperBound..<text.endIndex))
        let pulse = text[pulseStart.lowerBound..<tintStart.lowerBound]
        let tint = text[tintStart.lowerBound...]

        XCTAssertTrue(pulse.contains("if case .syncing = self.state { return true }"))
        XCTAssertFalse(pulse.contains(".connecting"))
        XCTAssertTrue(tint.contains("case .connecting, .offline, .notPaired: .secondary"))
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
