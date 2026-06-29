// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func screencastSourceState(for state: ScreencastManager.State) -> SourceState {
    switch state {
    case .off:
        .off
    case .starting:
        .enrolling
    case .active:
        .active
    case .needsAttention, .unavailable:
        .needsAttention
    }
}
