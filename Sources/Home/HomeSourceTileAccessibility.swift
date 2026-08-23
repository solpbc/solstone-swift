// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct HomeSourceTileAccessibilityFacts: Equatable, Sendable {
    let takingItIn: String
    let verdict: String

    var value: String { "\(self.takingItIn), \(self.verdict)" }

    fileprivate static func takingItIn(_ state: SourceState) -> String {
        switch state {
        case .active:
            "dev-copy: taking it in now"
        case .off, .enrolling, .readyToSetUp, .checking, .paused, .needsAttention:
            "dev-copy: not taking it in now"
        }
    }

    fileprivate static func verdict(_ state: SourceState) -> String {
        switch state {
        case .off, .enrolling, .active, .paused:
            "good"
        case .readyToSetUp:
            "unavailable"
        case .checking, .needsAttention:
            "degraded"
        }
    }
}

nonisolated func homeSourceTileAccessibilityFacts(
    for state: SourceState
) -> HomeSourceTileAccessibilityFacts {
    HomeSourceTileAccessibilityFacts(
        takingItIn: HomeSourceTileAccessibilityFacts.takingItIn(state),
        verdict: HomeSourceTileAccessibilityFacts.verdict(state)
    )
}
