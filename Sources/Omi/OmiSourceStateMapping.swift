// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func omiSourceState(
    for state: OmiSourceState,
    enabled: Bool
) -> (SourceState, SourceAttention?) {
    guard enabled else {
        return (.off, nil)
    }

    switch state {
    case .disconnected, .connecting, .reconnecting:
        return (.enrolling, nil)
    case .connected:
        return (.active, nil)
    case .needsAttention(let reason):
        return (.needsAttention, SourceAttention(message: reason.displayString))
    }
}
