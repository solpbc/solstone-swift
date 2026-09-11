// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// `enrolled` is the owner's own record that they set audio up at least once.
///
/// Without it an idle manager is indistinguishable from one the owner switched off,
/// and `off` is the owner's *intent* — so a fresh install would claim a decision
/// nobody made. ⛔ `enrolled` is never inferred from the manager's state; it is read
/// from what the owner actually did.
nonisolated func sourceState(for observerState: ObserverState, paused: Bool, enrolled: Bool) -> SourceState {
    switch observerState {
    case .error(.permissionDenied) where !enrolled:
        // ⛔ Not a fault. The owner was asked for the microphone and said no, so nothing
        // they set up has stopped working — there is no evidence the permission was ever
        // held. `needs attention` here would be a diagnosis of a thing that never started.
        // The recovery route survives the word: the detail screen offers ios settings off
        // the manager's own error state, not off this one.
        .readyToSetUp
    case .error:
        .needsAttention
    case .starting:
        .enrolling
    case .active, .stopping:
        .active
    case .idle:
        if paused {
            .paused
        } else {
            enrolled ? .off : .readyToSetUp
        }
    }
}
