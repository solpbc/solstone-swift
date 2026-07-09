// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum TransferPacingMode: Equatable, Sendable {
    case normal
    case finishSyncing
}

nonisolated struct TransferDispatchConditions: Equatable, Sendable {
    var thermalState: ProcessInfo.ThermalState
    var lowPowerModeEnabled: Bool
    var isExpensive: Bool
    var isConstrained: Bool
}

nonisolated struct TransferDispatchDecision: Equatable, Sendable {
    var maxConcurrent: Int
    var interItemDelay: Duration
    var paused: Bool
}

nonisolated struct TransferDispatchPolicyDefaults: Equatable, Sendable {
    static let standard = TransferDispatchPolicyDefaults()

    var normalConcurrency: Int = 2
    var throttledConcurrency: Int = 1
    var throttledInterItemDelay: Duration = .milliseconds(500)
}

nonisolated struct TransferDispatchPolicy: Equatable, Sendable {
    var defaults: TransferDispatchPolicyDefaults

    init(defaults: TransferDispatchPolicyDefaults = .standard) {
        self.defaults = defaults
    }

    func decide(conditions: TransferDispatchConditions, mode: TransferPacingMode) -> TransferDispatchDecision {
        if conditions.thermalState == .critical {
            return TransferDispatchDecision(
                maxConcurrent: self.defaults.throttledConcurrency,
                interItemDelay: .zero,
                paused: true
            )
        }

        var lanes = self.defaults.normalConcurrency
        var delay = Duration.zero
        let thermalThrottled = conditions.thermalState == .serious
        let powerThrottled = conditions.lowPowerModeEnabled && mode != .finishSyncing
        if thermalThrottled || powerThrottled {
            lanes = self.defaults.throttledConcurrency
            delay = self.defaults.throttledInterItemDelay
        }
        if conditions.isConstrained || conditions.isExpensive {
            lanes = min(lanes, self.defaults.throttledConcurrency)
        }

        return TransferDispatchDecision(maxConcurrent: lanes, interItemDelay: delay, paused: false)
    }
}

nonisolated protocol TransferConditionsProviding: Sendable {
    func current() -> TransferDispatchConditions
}

nonisolated func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
        "nominal"
    case .fair:
        "fair"
    case .serious:
        "serious"
    case .critical:
        "critical"
    @unknown default:
        "unknown"
    }
}
