// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Observation

enum ObserverCommand: Equatable, Sendable {
    case stopRequested
}

@Observable
final class PendingObserverCommandState {
    var command: ObserverCommand?
}
