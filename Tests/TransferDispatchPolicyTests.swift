// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class TransferDispatchPolicyTests: XCTestCase {
    func testAC1PolicyTable() {
        let policy = TransferDispatchPolicy()
        let rows: [(String, TransferDispatchConditions, TransferPacingMode, TransferDispatchDecision)] = [
            (
                "normal nominal",
                self.conditions(),
                .normal,
                TransferDispatchDecision(maxConcurrent: 2, interItemDelay: .zero, paused: false)
            ),
            (
                "low power normal",
                self.conditions(lowPowerModeEnabled: true),
                .normal,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .milliseconds(500), paused: false)
            ),
            (
                "thermal serious",
                self.conditions(thermalState: .serious),
                .normal,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .milliseconds(500), paused: false)
            ),
            (
                "thermal critical",
                self.conditions(thermalState: .critical),
                .normal,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .zero, paused: true)
            ),
            (
                "thermal critical finish syncing",
                self.conditions(thermalState: .critical),
                .finishSyncing,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .zero, paused: true)
            ),
            (
                "constrained alone",
                self.conditions(isConstrained: true),
                .normal,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .zero, paused: false)
            ),
            (
                "expensive alone",
                self.conditions(isExpensive: true),
                .normal,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .zero, paused: false)
            ),
            (
                "constrained serious",
                self.conditions(thermalState: .serious, isConstrained: true),
                .normal,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .milliseconds(500), paused: false)
            ),
            (
                "low power finish syncing",
                self.conditions(lowPowerModeEnabled: true),
                .finishSyncing,
                TransferDispatchDecision(maxConcurrent: 2, interItemDelay: .zero, paused: false)
            ),
            (
                "serious finish syncing",
                self.conditions(thermalState: .serious),
                .finishSyncing,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .milliseconds(500), paused: false)
            ),
            (
                "constrained finish syncing",
                self.conditions(isConstrained: true),
                .finishSyncing,
                TransferDispatchDecision(maxConcurrent: 1, interItemDelay: .zero, paused: false)
            ),
            (
                "fair thermal",
                self.conditions(thermalState: .fair),
                .normal,
                TransferDispatchDecision(maxConcurrent: 2, interItemDelay: .zero, paused: false)
            ),
        ]

        for (name, conditions, mode, expected) in rows {
            XCTAssertEqual(policy.decide(conditions: conditions, mode: mode), expected, name)
        }
    }

    private func conditions(
        thermalState: ProcessInfo.ThermalState = .nominal,
        lowPowerModeEnabled: Bool = false,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) -> TransferDispatchConditions {
        TransferDispatchConditions(
            thermalState: thermalState,
            lowPowerModeEnabled: lowPowerModeEnabled,
            isExpensive: isExpensive,
            isConstrained: isConstrained
        )
    }
}
