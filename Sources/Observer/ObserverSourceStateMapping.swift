// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func sourceState(for observerState: ObserverState, paused: Bool) -> SourceState {
    switch observerState {
    case .error:
        .needsAttention
    case .starting:
        .enrolling
    case .active, .stopping:
        .active
    case .idle:
        paused ? .paused : .off
    }
}
